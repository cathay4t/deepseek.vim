scriptencoding utf-8

let s:deferred = []

function! deepseek#util#Nop(...) abort
  return v:null
endfunction

function! deepseek#util#Defer(fn, ...) abort
  call add(s:deferred, function(a:fn, a:000))
  return timer_start(0, function('s:RunDeferred'))
endfunction

function! s:RunDeferred(...) abort
  if empty(s:deferred)
    return
  endif
  let Fn = remove(s:deferred, 0)
  call timer_start(0, function('s:RunDeferred'))
  call call(Fn, [])
endfunction

function! deepseek#util#GetContext() abort
  let line = getline('.')
  let col = col('.') - 1
  let lnum = line('.')

  let before_line = strpart(line, 0, col)
  let after_line = strpart(line, col)

  let before_lines = getline(max([1, lnum - 100]), lnum - 1)
  let after_lines = getline(lnum + 1, min([line('$'), lnum + 50]))

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
