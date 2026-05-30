scriptencoding utf-8

let s:has_nvim_ghost_text = has('nvim-0.8')
let s:vim_minimum_version = '9.0.0185'
let s:has_vim_ghost_text = has('patch-' . s:vim_minimum_version) && has('textprop')
let s:has_ghost_text = s:has_nvim_ghost_text || s:has_vim_ghost_text

let s:hlgroup = 'DeepseekSuggestion'
let s:annot_hlgroup = 'DeepseekAnnotation'

if s:has_vim_ghost_text && empty(prop_type_get(s:hlgroup))
  call prop_type_add(s:hlgroup, {'highlight': s:hlgroup})
endif
if s:has_vim_ghost_text && empty(prop_type_get(s:annot_hlgroup))
  call prop_type_add(s:annot_hlgroup, {'highlight': s:annot_hlgroup})
endif

function! deepseek#Init(...) abort
  call deepseek#util#Defer({ -> s:Start() })
endfunction

function! s:Running() abort
  return deepseek#client#Running()
endfunction

function! s:Start() abort
  if s:Running()
    return
  endif
  let result = deepseek#client#Start()
  if type(result) == v:t_string
    let s:startup_error = result
  endif
endfunction

function! s:Stop() abort
  call deepseek#client#Stop()
endfunction

function! deepseek#Clear() abort
  if exists('g:_deepseek_timer')
    call timer_stop(remove(g:, '_deepseek_timer'))
  endif
  if exists('b:_deepseek')
    call deepseek#client#Cancel(get(b:_deepseek, 'request', {}))
  endif
  call s:ClearPreview()
  unlet! b:_deepseek
  return ''
endfunction

function! deepseek#Dismiss() abort
  call deepseek#Clear()
  call s:ClearPreview()
  return ''
endfunction

let s:filetype_defaults = {
      \ 'gitcommit': 0,
      \ 'gitrebase': 0,
      \ 'hgcommit': 0,
      \ 'svn': 0,
      \ 'cvs': 0,
      \ '.': 0}

function! s:BufferDisabled() abort
  if &buftype =~# '^\%(help\|prompt\|quickfix\|terminal\)$'
    return 5
  endif
  if exists('b:deepseek_disabled')
    return empty(b:deepseek_disabled) ? 0 : 3
  endif
  if exists('b:deepseek_enabled')
    return empty(b:deepseek_enabled) ? 4 : 0
  endif
  let short = empty(&l:filetype) ? '.' : split(&l:filetype, '\.', 1)[0]
  let config = {}
  if type(get(g:, 'deepseek_filetypes')) == v:t_dict
    let config = g:deepseek_filetypes
  endif
  if has_key(config, &l:filetype)
    return empty(config[&l:filetype])
  elseif has_key(config, short)
    return empty(config[short])
  elseif has_key(config, '*')
    return empty(config['*'])
  else
    return get(s:filetype_defaults, short, 1) == 0 ? 2 : 0
  endif
endfunction

function! deepseek#Enabled() abort
  return get(g:, 'deepseek_enabled', 1)
        \ && empty(s:BufferDisabled())
endfunction

function! s:Complete(...) abort
  if exists('g:_deepseek_timer')
    call timer_stop(remove(g:, '_deepseek_timer'))
  endif
  let target = [bufnr(''), getbufvar('', 'changedtick'), line('.'), col('.')]
  if !exists('b:_deepseek.target') || b:_deepseek.target !=# target
    if exists('b:_deepseek.request')
      call deepseek#client#Cancel(b:_deepseek.request)
    endif
    let [prompt, suffix] = deepseek#util#GetContext()
    let params = {
          \ 'prompt': prompt,
          \ 'suffix': suffix,
          \ 'model': get(g:, 'deepseek_model', 'deepseek-v4-flash'),
          \ 'max_tokens': get(g:, 'deepseek_max_tokens', 256)}
    let b:_deepseek = {
          \ 'target': target,
          \ 'params': params,
          \ 'request': deepseek#client#Request('complete', params)}
  endif
  let request = b:_deepseek.request
  if !a:0
    return request.Await()
  else
    call deepseek#client#Result(request, function(a:1, [b:_deepseek]))
    if a:0 > 1
      call deepseek#client#Error(request, function(a:2, [b:_deepseek]))
    endif
  endif
endfunction

function! s:HideDuringCompletion() abort
  return get(g:, 'deepseek_hide_during_completion', 1)
endfunction

function! s:SuggestionTextWithAdjustments() abort
  let empty = ['', 0, '', {}]
  try
    if mode() !~# '^[iR]' || (s:HideDuringCompletion() && pumvisible())
          \ || !exists('b:_deepseek.suggestions')
      return empty
    endif
    let choice = get(b:_deepseek.suggestions, b:_deepseek.choice, {})
    if !has_key(choice, 'text') || type(choice.text) !=# v:t_string
      return empty
    endif
    let line = getline('.')
    let offset = col('.') - 1
    let suggestion = substitute(substitute(substitute(choice.text, '\r\n', '\n', 'g'), '\r', '\n', 'g'), '\n*$', '', '')
    let line_before = strpart(line, 0, offset)
    let line_after = strpart(line, offset)
    if line_before =~# '^\s*$'
      let leading = matchstr(suggestion, '^\s\+')
      let trimmed = substitute(suggestion, '^\s\+', '', '')
      if trimmed !=# line_after
        return [trimmed, len(leading), line_after, choice]
      endif
    else
      return [suggestion, 0, line_after, choice]
    endif
  catch
  endtry
  return empty
endfunction

function! s:Advance(count, context, ...) abort
  if a:context isnot# get(b:, '_deepseek', {})
    return
  endif
  let a:context.choice += a:count
  if a:context.choice < 0
    let a:context.choice += len(a:context.suggestions)
  endif
  let a:context.choice %= len(a:context.suggestions)
  call s:UpdatePreview()
endfunction

function! deepseek#Next() abort
  if exists('b:_deepseek.suggestions')
    call s:Advance(1, b:_deepseek)
  endif
  return ''
endfunction

function! deepseek#Previous() abort
  if exists('b:_deepseek.suggestions')
    call s:Advance(-1, b:_deepseek)
  endif
  return ''
endfunction

function! deepseek#GetDisplayedSuggestion() abort
  let [text, outdent, delete_chars, item] = s:SuggestionTextWithAdjustments()
  return {
        \ 'item': item,
        \ 'text': text,
        \ 'outdentSize': outdent,
        \ 'deleteSize': strchars(delete_chars),
        \ 'deleteChars': delete_chars}
endfunction

function! s:ClearPreview() abort
  if s:has_nvim_ghost_text
    try
      call nvim_buf_del_extmark(0, deepseek#NvimNs(), 1)
    catch
    endtry
  elseif s:has_vim_ghost_text
    call prop_remove({'type': s:hlgroup, 'all': v:true})
    call prop_remove({'type': s:annot_hlgroup, 'all': v:true})
  endif
endfunction

function! deepseek#NvimNs() abort
  return nvim_create_namespace('deepseek')
endfunction

function! s:UpdatePreview() abort
  try
    let [text, outdent, delete_chars, item] = s:SuggestionTextWithAdjustments()
    let delete = strchars(delete_chars)
    let text_lines = split(substitute(text, "\r\n", "\n", "g"), "\n", 1)
    if empty(text_lines[-1])
      call remove(text_lines, -1)
    endif
    if empty(text_lines) || !s:has_ghost_text
      return s:ClearPreview()
    endif
    let annot = ''
    if exists('b:_deepseek.suggestions') && len(b:_deepseek.suggestions) > 1
      let annot = '(' . (b:_deepseek.choice + 1) . '/' . len(b:_deepseek.suggestions) . ')'
    endif
    call s:ClearPreview()
    if s:has_nvim_ghost_text
      let data = {'id': 1}
      let data.virt_text_pos = 'overlay'
      let append = strpart(getline('.'), col('.') - 1 + delete)
      let data.virt_text = [[text_lines[0] . append . repeat(' ', delete - len(text_lines[0])), s:hlgroup]]
      if len(text_lines) > 1
        let data.virt_lines = map(text_lines[1:-1], { _, l -> [[l, s:hlgroup]] })
        if !empty(annot)
          let data.virt_lines[-1] += [[' '], [annot, s:annot_hlgroup]]
        endif
      elseif !empty(annot)
        let data.virt_text += [[' '], [annot, s:annot_hlgroup]]
      endif
      let data.hl_mode = 'combine'
      call nvim_buf_set_extmark(0, deepseek#NvimNs(), line('.')-1, col('.')-1, data)
    elseif s:has_vim_ghost_text
      let new_suffix = text_lines[0]
      let current_suffix = getline('.')[col('.') - 1 :]
      let inset = ''
      while delete > 0 && !empty(new_suffix)
        let last_char = matchstr(new_suffix, '.$')
        let new_suffix = matchstr(new_suffix, '^.\{-\}\ze.$')
        if last_char ==# matchstr(current_suffix, '.$')
          if !empty(inset)
            call prop_add(line('.'), col('.') + len(current_suffix), {'type': s:hlgroup, 'text': inset})
            let inset = ''
          endif
          let current_suffix = matchstr(current_suffix, '^.\{-\}\ze.$')
          let delete -= 1
        else
          let inset = last_char . inset
        endif
      endwhile
      if !empty(new_suffix . inset)
        call prop_add(line('.'), col('.'), {'type': s:hlgroup, 'text': new_suffix . inset})
      endif
      for line_text in text_lines[1:]
        call prop_add(line('.'), 0, {'type': s:hlgroup, 'text_align': 'below', 'text': line_text})
      endfor
      if !empty(annot)
        call prop_add(line('.'), col('$'), {'type': s:annot_hlgroup, 'text': ' ' . annot})
      endif
    endif
  catch
  endtry
endfunction

function! s:HandleTriggerResult(state, request) abort
  if a:request.status !=# 'success'
    return
  endif
  let result = a:request.result
  let text = get(result, 'text', '')
  if empty(text)
    let a:state.suggestions = []
  else
    let a:state.suggestions = [{'text': text, 'finish_reason': get(result, 'finish_reason', 'stop')}]
  endif
  let a:state.choice = 0
  if get(b:, '_deepseek') is# a:state
    call s:UpdatePreview()
  endif
endfunction

function! s:HandleTriggerError(state, request) abort
  let a:state.suggestions = []
  let a:state.choice = 0
  let a:state.error = a:request
  if get(b:, '_deepseek') is# a:state
    call s:ClearPreview()
  endif
endfunction

function! deepseek#Suggest() abort
  if !s:Running()
    return ''
  endif
  try
    call s:Complete(function('s:HandleTriggerResult'), function('s:HandleTriggerError'))
  catch
  endtry
  return ''
endfunction

function! s:Trigger(bufnr, timer) abort
  let timer = get(g:, '_deepseek_timer', -1)
  if a:bufnr !=# bufnr('') || a:timer isnot# timer || mode() !=# 'i'
    return
  endif
  unlet! g:_deepseek_timer
  return deepseek#Suggest()
endfunction

function! deepseek#Schedule() abort
  if !s:has_ghost_text || !s:Running() || !deepseek#Enabled()
    call deepseek#Clear()
    return
  endif
  call s:UpdatePreview()
  let delay = get(g:, 'deepseek_idle_delay', 1000)
  call timer_stop(get(g:, '_deepseek_timer', -1))
  let g:_deepseek_timer = timer_start(delay, function('s:Trigger', [bufnr('')]))
endfunction

function! deepseek#OnInsertLeavePre() abort
  call deepseek#Clear()
  call s:ClearPreview()
endfunction

function! deepseek#OnInsertEnter() abort
  return deepseek#Schedule()
endfunction

function! deepseek#OnCompleteChanged() abort
  if s:HideDuringCompletion()
    return deepseek#Clear()
  else
    return deepseek#Schedule()
  endif
endfunction

function! deepseek#OnCursorMovedI() abort
  return deepseek#Schedule()
endfunction

function! deepseek#OnBufUnload() abort
endfunction

function! deepseek#OnVimLeavePre() abort
  call s:Stop()
endfunction

function! deepseek#TextQueuedForInsertion() abort
  try
    return remove(s:, 'suggestion_text')
  catch
    return ''
  endtry
endfunction

function! deepseek#Accept(...) abort
  let s = deepseek#GetDisplayedSuggestion()
  if !empty(s.text)
    unlet! b:_deepseek
    call s:ClearPreview()
    let s:suggestion_text = s.text
    let recall = s.text =~# "\n" ? "\<C-R>\<C-O>=" : "\<C-R>\<C-R>="
    return repeat("\<Left>\<Del>", s.outdentSize) . repeat("\<Del>", s.deleteSize) .
          \ recall . "deepseek#TextQueuedForInsertion()\<CR>" . "\<End>"
  endif
  let default = get(g:, 'deepseek_tab_fallback', pumvisible() ? "\<C-N>" : "\t")
  if !a:0
    return default
  elseif type(a:1) == v:t_string
    return a:1
  elseif type(a:1) == v:t_func
    try
      return call(a:1, [])
    catch
      return default
    endtry
  else
    return default
  endif
endfunction

function! deepseek#AcceptWord(...) abort
  return deepseek#Accept(a:0 ? a:1 : '', '\%(\k\@!.\)*\k*')
endfunction

function! deepseek#AcceptLine(...) abort
  return deepseek#Accept(a:0 ? a:1 : "\r", "[^\n]\\+")
endfunction

function! s:EnabledStatusMessage() abort
  let buf_disabled = s:BufferDisabled()
  if !s:has_ghost_text
    if has('nvim')
      return "Neovim 0.6 required to support ghost text"
    else
      return "Vim " . s:vim_minimum_version . " required to support ghost text"
    endif
  elseif !get(g:, 'deepseek_enabled', 1)
    return 'Disabled globally by :Deepseek disable'
  elseif buf_disabled is# 5
    return 'Disabled for current buffer by buftype=' . &buftype
  elseif buf_disabled is# 4
    return 'Disabled for current buffer by b:deepseek_enabled'
  elseif buf_disabled is# 3
    return 'Disabled for current buffer by b:deepseek_disabled'
  elseif buf_disabled is# 2
    return 'Disabled for filetype=' . &filetype . ' by internal default'
  elseif buf_disabled
    return 'Disabled for filetype=' . &filetype . ' by g:deepseek_filetypes'
  elseif !deepseek#Enabled()
    return 'Something is wrong with enabling/disabling'
  else
    return ''
  endif
endfunction

let s:commands = {}

function! s:commands.status(opts) abort
  if exists('s:startup_error')
    echo 'Deepseek: ' . s:startup_error
    return
  endif
  let status = s:EnabledStatusMessage()
  if !empty(status)
    echo 'Deepseek: ' . status
    return
  endif
  echo 'Deepseek: Ready'
endfunction

function! s:commands.setup(opts) abort
  if exists('s:startup_error')
    echo 'Deepseek: ' . s:startup_error
    return
  endif
  let key = get(g:, 'deepseek_api_key', '')
  if empty(key)
    let key = inputsecret('DeepSeek API Key: ')
    if !empty(key)
      let g:deepseek_api_key = key
      call s:Stop()
      call s:Start()
      call deepseek#client#Request('init', {'api_key': key})
    endif
  endif
  if !empty(key)
    echo 'Deepseek: API key configured'
  else
    echo 'Deepseek: No API key provided. Set g:deepseek_api_key or DEEPSEEK_VIM_API_KEY env'
  endif
endfunction

function! s:commands.enable(opts) abort
  let g:deepseek_enabled = 1
endfunction

function! s:commands.disable(opts) abort
  let g:deepseek_enabled = 0
endfunction

function! s:commands.toggle(opts) abort
  let g:deepseek_enabled = !get(g:, 'deepseek_enabled', 1)
endfunction

function! s:commands.version(opts) abort
  echo 'deepseek.vim ' . s:plugin_version
  if s:Running()
    echo 'Agent running'
  else
    echo 'Agent not running'
  endif
endfunction

function! s:commands.restart(opts) abort
  call s:Stop()
  unlet! s:startup_error
  call s:Start()
  echo 'Deepseek: Agent restarted'
endfunction

function! s:commands.help(opts) abort
  return a:opts.mods . ' help ' . (len(a:opts.arg) ? ':Deepseek_' . a:opts.arg : 'deepseek')
endfunction


function! deepseek#CommandComplete(arg, lead, pos) abort
  let args = matchstr(strpart(a:lead, 0, a:pos), 'D\%[eepseek][! ] *\zs.*')
  if args !~# ' '
    return sort(filter(keys(s:commands),
          \ { k, v -> strpart(v, 0, len(a:arg)) ==# a:arg }))
  else
    return []
  endif
endfunction

function! deepseek#Command(line1, line2, range, bang, mods, arg) abort
  let cmd = matchstr(a:arg, '^\%(\\.\|\S\)\+')
  let arg = matchstr(a:arg, '\s\zs\S.*')
  if !empty(cmd) && !has_key(s:commands, cmd)
    return 'echoerr ' . string('Deepseek: unknown command ' . string(cmd))
  endif
  try
    if empty(cmd)
      let cmd = 'status'
    endif
    let opts = {'line1': a:line1, 'line2': a:line2, 'range': a:range, 'bang': a:bang, 'mods': a:mods, 'arg': arg}
    let retval = s:commands[cmd](opts)
    if type(retval) == v:t_string
      return retval
    else
      return ''
    endif
  catch /^Deepseek:/
    return 'echoerr ' . string(v:exception)
  endtry
endfunction

let s:plugin_version = deepseek#version#String()
