scriptencoding utf-8

let s:deferred = []
let s:deferred_pending = 0

function! deepseek#util#Nop(...) abort
  return v:null
endfunction

function! deepseek#util#Defer(fn, ...) abort
  call add(s:deferred, function(a:fn, a:000))
  if !s:deferred_pending
    let s:deferred_pending = 1
    call timer_start(0, function('s:RunDeferred'))
  endif
endfunction

function! s:RunDeferred(...) abort
  while !empty(s:deferred)
    let Fn = remove(s:deferred, 0)
    call call(Fn, [])
  endwhile
  let s:deferred_pending = 0
endfunction

function! deepseek#util#GetContext() abort
  let line = getline('.')
  let col = col('.') - 1
  let lnum = line('.')

  let before_line = strpart(line, 0, col)
  let after_line = strpart(line, col)

  let before_count = get(g:, 'deepseek_context_before_lines', 100)
  let after_count = get(g:, 'deepseek_context_after_lines', 50)

  let before_lines = getline(max([1, lnum - before_count]), lnum - 1)
  let after_lines = getline(lnum + 1, min([line('$'), lnum + after_count]))

  let prompt = join(before_lines, "\n")
  if !empty(prompt)
    let prompt .= "\n"
  endif
  let prompt .= before_line

  let suffix = after_line
  if !empty(after_lines)
    if !empty(suffix)
      let suffix .= "\n"
    endif
    let suffix .= join(after_lines, "\n")
  endif

  return [prompt, suffix]
endfunction
