# Use deepseek in vim for auto-completion

This is just a copy-cat of https://github.com/github/copilot.vim but using
deepseek API instead.

__This project is not affiliated with or endorsed by Github or Deekseek.__

__This project created by AI with human assistant only, use at your own risk.__

## Howto

To enable this plugin in your vim/neovim, add these lines into your `vimrc`:

```
Plug "cathay4t/deepseek.vim"

let g:deepseek_api_key = 'your-api-key-here'
" Optional: set model
" let g:deepseek_model = 'deepseek-v4-pro'
```

The completion request fires after a debounce delay (default 1000ms) after your
last keystroke. Adjust with:

```
" lower = more responsive, higher = fewer API calls
let g:deepseek_idle_delay = 300
```

To limit this feature to selected file types:

```
let g:deepseek_filetypes = {
            \ '*': v:false,
            \ 'python': v:false,
            \ 'rust': v:true,
            \ 'c': v:true,
            \ 'markdown': v:true}
```

To disable this feature on selected file:

```
autocmd BufRead,BufNewFile */Source/my-leetcode/*.rs
                        \ set b:deepseek_enabled = 0
```

## License

Apache 2.0
