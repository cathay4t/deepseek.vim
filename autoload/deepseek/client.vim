scriptencoding utf-8

let s:plugin_version = deepseek#version#String()
let s:root = expand('<sfile>:h:h:h')

if !exists('s:id')
  let s:id = 0
endif

let s:error_canceled = {'code': -32800, 'message': 'Canceled'}
let s:error_exit = {'code': -32097, 'message': 'Process exited'}
let s:error_connection_inactive = {'code': -32096, 'message': 'Connection inactive'}

function! s:RejectRequest(request, error) abort
  if a:request.status !=# 'running'
    return
  endif
  let reject = remove(a:request, 'reject')
  let a:request.status = 'error'
  let a:request.error = deepcopy(a:error)
  for Cb in reject
    call Cb(a:request)
  endfor
endfunction

function! s:OnStdout(instance, ch, msg) abort
  if !has_key(a:instance, 'job')
    return
  endif
  let a:instance.buffer .= a:msg
  while 1
    let nl = stridx(a:instance.buffer, "\n")
    if nl < 0
      break
    endif
    let line = strpart(a:instance.buffer, 0, nl)
    let a:instance.buffer = strpart(a:instance.buffer, nl + 1)
    if empty(line)
      continue
    endif
    try
      let response = json_decode(line)
    catch
      continue
    endtry
    let id = get(response, 'id', v:null)
    if !has_key(a:instance.requests, id)
      continue
    endif
    let request = remove(a:instance.requests, id)
    if request.status !=# 'running'
      continue
    endif
    if has_key(response, 'result')
      let resolve = remove(request, 'resolve')
      call remove(request, 'reject')
      let request.status = 'success'
      let request.result = response.result
      for Cb in resolve
        call Cb(request)
      endfor
    elseif has_key(response, 'error')
      call s:RejectRequest(request, response.error)
    endif
  endwhile
endfunction

function! s:OnStderr(instance, ch, msg, ...) abort
  if !has_key(a:instance, 'stderr')
    let a:instance.stderr = ''
  endif
  let a:instance.stderr .= a:msg
endfunction

function! s:OnExit(instance, job, code) abort
  let a:instance.exit_status = a:code
  if has_key(a:instance, 'job')
    call remove(a:instance, 'job')
  endif
  if !empty(a:instance.buffer) && stridx(a:instance.buffer, "\n") < 0
    try
      let response = json_decode(a:instance.buffer)
      let id = get(response, 'id', v:null)
      if has_key(a:instance.requests, id)
        let request = remove(a:instance.requests, id)
        if request.status ==# 'running'
          if has_key(response, 'result')
            let resolve = remove(request, 'resolve')
            call remove(request, 'reject')
            let request.status = 'success'
            let request.result = response.result
            for Cb in resolve
              call Cb(request)
            endfor
          elseif has_key(response, 'error')
            call s:RejectRequest(request, response.error)
          endif
        endif
      endif
    catch
    endtry
  endif
  for id in sort(keys(a:instance.requests))
    call s:RejectRequest(remove(a:instance.requests, id), s:error_exit)
  endfor
  if a:code != 0 && !has_key(a:instance, 'kill')
    let a:instance.startup_error = 'Agent exited with status ' . a:code
  endif
endfunction

function! s:OnInitError(instance, request) abort
  if !has_key(a:instance, 'startup_error') && a:request.status ==# 'error'
    let a:instance.startup_error = 'Init failed: ' . get(get(a:request, 'error', {}), 'message', '')
  endif
endfunction

function! s:Send(instance, data) abort
  if !has_key(a:instance, 'job')
    return v:false
  endif
  try
    call ch_sendraw(a:instance.job, a:data)
    return v:true
  catch
    return v:false
  endtry
endfunction

function! s:RequestWait() dict abort
  while self.status ==# 'running'
    sleep 1m
  endwhile
  return self
endfunction

function! s:RequestAwait() dict abort
  call self.Wait()
  if has_key(self, 'result')
    return self.result
  endif
  throw 'Deepseek:E' . self.error.code . ': ' . self.error.message
endfunction

function! s:RequestCancel() dict abort
  let request = self
  if request.status ==# 'running'
    call s:RejectRequest(request, s:error_canceled)
  endif
endfunction

function! s:DoRequest(method, params, ...) dict abort
  let s:id += 1
  let request = {
        \ 'id': s:id,
        \ 'status': 'running',
        \ 'Wait': function('s:RequestWait'),
        \ 'Await': function('s:RequestAwait'),
        \ 'Cancel': function('s:RequestCancel'),
        \ 'resolve': [],
        \ 'reject': []}
  let args = a:000
  if len(args) && !empty(a:1)
    call add(request.resolve, a:1)
  endif
  if len(args) > 1 && !empty(a:2)
    call add(request.reject, a:2)
  endif
  let data = json_encode({'id': s:id, 'method': a:method, 'params': a:params}) . "\n"
  let self.requests[s:id] = request
  if !s:Send(self, data)
    call remove(self.requests, s:id)
    call s:RejectRequest(request, {'code': -32603, 'message': 'Failed to send request to agent'})
  endif
  return request
endfunction

function! s:StartAgent() abort
  let python_cmd = get(g:, 'deepseek_python_command', 'python3')
  let agent_script = s:root . '/agent/deepseek_agent.py'

  if !executable(python_cmd)
    return 'Python executable `' . python_cmd . "' not found"
  endif
  if !filereadable(agent_script)
    return 'Agent script not found: ' . agent_script
  endif

  let instance = {
        \ 'requests': {},
        \ 'buffer': '',
        \ 'Close': function('s:CloseAgent'),
        \ 'Request': function('s:DoRequest'),
        \ 'startup_error': v:null,
        \ 'exit_status': v:null}

  let job = job_start([python_cmd, agent_script], {
        \ 'in_mode': 'raw',
        \ 'out_mode': 'raw',
        \ 'out_cb': function('s:OnStdout', [instance]),
        \ 'err_cb': function('s:OnStderr', [instance]),
        \ 'exit_cb': function('s:OnExit', [instance]),
        \ 'stoponexit': '',
        \ 'noblock': 1})

  if job_status(job) ==# 'fail'
    return 'Failed to start agent process'
  endif

  let instance.job = job
  let s:instance = instance

  let api_key = get(g:, 'deepseek_api_key', '')
  let init_req = instance.Request('init', {'api_key': api_key})
  if !empty(init_req)
    call deepseek#client#Error(init_req, function('s:OnInitError', [instance]))
  endif

  return instance
endfunction

function! s:CloseAgent() dict abort
  if !has_key(self, 'job')
    return
  endif
  let self.kill = v:true
  call job_stop(self.job)
  call remove(self, 'job')
endfunction

function! deepseek#client#Start() abort
  if exists('s:instance')
    if has_key(s:instance, 'job') && job_status(s:instance.job) ==# 'run'
      return s:instance
    endif
    call remove(s:, 'instance')
  endif
  let result = s:StartAgent()
  if type(result) == v:t_string
    return result
  endif
  return result
endfunction

function! deepseek#client#Running() abort
  if !exists('s:instance') || !has_key(s:instance, 'job')
    return v:false
  endif
  if job_status(s:instance.job) !=# 'run'
    return v:false
  endif
  if !empty(get(s:instance, 'startup_error', v:null))
    return v:false
  endif
  return v:true
endfunction

function! deepseek#client#StartupError() abort
  let instance = get(s:, 'instance', {})
  return get(instance, 'startup_error', v:null)
endfunction

function! deepseek#client#Instance() abort
  return get(s:, 'instance', v:null)
endfunction

function! deepseek#client#Request(method, params, ...) abort
  let instance = deepseek#client#Instance()
  if empty(instance)
    return v:null
  endif
  return call(instance.Request, [a:method, a:params] + a:000)
endfunction

function! deepseek#client#Cancel(request) abort
  if type(a:request) == type({}) && has_key(a:request, 'Cancel')
    call a:request.Cancel()
  endif
endfunction

function! deepseek#client#Result(request, callback) abort
  if has_key(a:request, 'resolve')
    call add(a:request.resolve, a:callback)
  elseif has_key(a:request, 'result')
    call a:callback(a:request)
  endif
endfunction

function! deepseek#client#Error(request, callback) abort
  if has_key(a:request, 'reject')
    call add(a:request.reject, a:callback)
  elseif has_key(a:request, 'error')
    call a:callback(a:request)
  endif
endfunction

function! deepseek#client#Stop() abort
  if exists('s:instance')
    call s:instance.Close()
    unlet! s:instance
  endif
endfunction
