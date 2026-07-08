if exists('g:loaded_deepseek')
  finish
endif
let g:loaded_deepseek = 1

scriptencoding utf-8

command! -bang -nargs=? -range=-1 -complete=customlist,deepseek#CommandComplete Deepseek exe deepseek#Command(<line1>, <count>, +"<range>", <bang>0, "<mods>", <q-args>)

if v:version < 800 || !exists('##InsertLeavePre')
  finish
endif

function! s:ColorScheme() abort
  if &t_Co == 256
    hi def DeepseekSuggestion guifg=#808080 ctermfg=244
  else
    hi def DeepseekSuggestion guifg=#808080 ctermfg=12
  endif
  hi def link DeepseekAnnotation MoreMsg
endfunction

function! s:MapTab() abort
  if get(g:, 'deepseek_no_tab_map') || get(g:, 'deepseek_no_maps')
    return
  endif
  let tab_map = maparg('<Tab>', 'i', 0, 1)
  if !has_key(tab_map, 'rhs')
    imap <script><silent><nowait><expr> <Tab> deepseek#Accept()
  elseif tab_map.rhs !~# 'deepseek'
    if tab_map.expr
      let tab_fallback = '{ -> ' . tab_map.rhs . ' }'
    else
      let tab_fallback = substitute(json_encode(tab_map.rhs), '<', '\\<', 'g')
    endif
    let tab_fallback = substitute(tab_fallback, '<SID>', '<SNR>' . get(tab_map, 'sid') . '_', 'g')
    if get(tab_map, 'noremap') || get(tab_map, 'script') || mapcheck('<Left>', 'i') || mapcheck('<Del>', 'i')
      exe 'imap <script><silent><nowait><expr> <Tab> deepseek#Accept(' . tab_fallback . ')'
    else
      exe 'imap <silent><nowait><expr>         <Tab> deepseek#Accept(' . tab_fallback . ')'
    endif
  endif
endfunction

function! s:Event(type) abort
  try
    call call('deepseek#On' . a:type, [])
  catch
  endtry
endfunction

augroup deepseek_plugin
  autocmd!
  autocmd InsertLeavePre       * call s:Event('InsertLeavePre')
  autocmd BufLeave             * if mode() =~# '^[iR]'|call s:Event('InsertLeavePre')|endif
  autocmd InsertEnter          * call s:Event('InsertEnter')
  autocmd BufEnter             * if mode() =~# '^[iR]'|call s:Event('InsertEnter')|endif
  autocmd CursorMovedI         * call s:Event('CursorMovedI')
  autocmd TextChangedI         * call s:Event('TextChangedI')
  autocmd CompleteChanged      * call s:Event('CompleteChanged')
  autocmd ColorScheme,VimEnter * call s:ColorScheme()
  autocmd VimEnter             * call s:MapTab() | call deepseek#Init()
  autocmd BufUnload            * call s:Event('BufUnload')
  autocmd VimLeavePre          * call s:Event('VimLeavePre')
augroup END

call s:ColorScheme()
call s:MapTab()
if !get(g:, 'deepseek_no_maps')
  imap <Plug>(deepseek-dismiss)     <Cmd>call deepseek#Dismiss()<CR>
  if empty(mapcheck('<C-]>', 'i'))
    imap <silent><script><nowait><expr> <C-]> deepseek#Dismiss() . "\<C-]>"
  endif
  imap <Plug>(deepseek-next)     <Cmd>call deepseek#Next()<CR>
  imap <Plug>(deepseek-previous) <Cmd>call deepseek#Previous()<CR>
  imap <Plug>(deepseek-suggest)  <Cmd>call deepseek#Suggest()<CR>
  imap <script><silent><nowait><expr> <Plug>(deepseek-accept-word) deepseek#AcceptWord()
  imap <script><silent><nowait><expr> <Plug>(deepseek-accept-line) deepseek#AcceptLine()
  try
    if !has('nvim') && &encoding ==# 'utf-8'
      let s:restore_encoding = 1
      silent noautocmd set encoding=cp949
    endif
    if empty(mapcheck('<M-]>', 'i'))
      imap <M-]> <Plug>(deepseek-next)
    endif
    if empty(mapcheck('<M-[>', 'i'))
      imap <M-[> <Plug>(deepseek-previous)
    endif
    if empty(mapcheck('<M-Bslash>', 'i'))
      imap <M-Bslash> <Plug>(deepseek-suggest)
    endif
    if empty(mapcheck('<M-Right>', 'i'))
      imap <M-Right> <Plug>(deepseek-accept-word)
    endif
    if empty(mapcheck('<M-C-Right>', 'i'))
      imap <M-C-Right> <Plug>(deepseek-accept-line)
    endif
  finally
    if exists('s:restore_encoding')
      silent noautocmd set encoding=utf-8
    endif
  endtry
endif

let s:dir = expand('<sfile>:h:h')
if getftime(s:dir . '/doc/deepseek.txt') > getftime(s:dir . '/doc/tags')
  silent! execute 'helptags' fnameescape(s:dir . '/doc')
endif
