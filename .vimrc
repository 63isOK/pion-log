" Specify a directory for plugins
" - For Neovim: stdpath('data') . '/plugged'
" - Avoid using standard Vim directory names like 'plugin'
call plug#begin('~/.vim/plugged')

" Make sure you use single quotes

" Shorthand notation; fetches https://github.com/junegunn/vim-easy-align
Plug 'junegunn/vim-easy-align'

" Any valid git URL is allowed
Plug 'https://github.com/junegunn/vim-github-dashboard.git'

" Multiple Plug commands can be written in a single line using | separators
Plug 'SirVer/ultisnips'

" On-demand loading
Plug 'scrooloose/nerdtree', { 'on':  'NERDTreeToggle' }
Plug 'tpope/vim-fireplace', { 'for': 'clojure' }

" Using a tagged release; wildcard allowed (requires git 1.9.2 or above)
Plug 'fatih/vim-go', { 'tag': '*' }
Plug 'vim-syntastic/syntastic'
Plug 'majutsushi/tagbar'
Plug 'vim-jp/vim-go-extra'
Plug 'rhysd/vim-go-impl'
Plug 'AndrewRadev/splitjoin.vim'
Plug 'tpope/vim-surround'
Plug 'tpope/vim-abolish'
Plug 'ycm-core/YouCompleteMe'

" if has('nvim')
"   Plug 'Shougo/deoplete.nvim', { 'do': ':UpdateRemotePlugins' }
" else
"   Plug 'Shougo/deoplete.nvim'
"   Plug 'roxma/nvim-yarp'
"   Plug 'roxma/vim-hug-neovim-rpc'
"  endif
" Plug 'deoplete-plugins/deoplete-go', { 'do': 'make'}

" md toc
Plug 'mzlogin/vim-markdown-toc'

" common
Plug 'Yggdroot/indentLine'
Plug 'mbbill/undotree'
Plug 'easymotion/vim-easymotion'
Plug 'terryma/vim-expand-region'
Plug 'tenfyzhong/CompleteParameter.vim'
Plug 'google/vim-searchindex'
Plug 'terryma/vim-multiple-cursors'
Plug 'Yggdroot/LeaderF', { 'do': './install.sh' }
Plug 'vim-airline/vim-airline'                                                  
Plug 'vim-airline/vim-airline-themes' 
Plug 'fatih/molokai'
Plug 'ctrlpvim/ctrlp.vim'
Plug 'scrooloose/nerdcommenter'
Plug 'wakatime/vim-wakatime'
Plug 'jiangmiao/auto-pairs'

" Plugin outside ~/.vim/plugged with post-update hook
Plug 'junegunn/fzf', { 'dir': '~/.fzf', 'do': './install --all' }
Plug 'junegunn/fzf.vim'

" Unmanaged plugin (manually installed and updated)

" Initialize plugin system
call plug#end()

set statusline+=%#warningmsg#
set statusline+=%{SyntasticStatuslineFlag()}
set statusline+=%*

let g:syntastic_always_populate_loc_list = 1
let g:syntastic_auto_loc_list = 1
let g:syntastic_check_on_open = 1
let g:syntastic_check_on_wq = 0

autocmd FileType go autocmd BufWritePre <buffer> Fmt

" let g:go_def_mode='gopls'
" let g:go_info_mode='gopls'

" vim-go-impl
" :GoImpl {receiver} {interface}

" defalut
set nocompatible                                                                
filetype plugin indent on
runtime macros/matchit.vim

syntax on                                                                       
syntax enable             
set rnu
set nu
filetype on
set foldmethod=syntax
set tabstop=2
set shiftwidth=2
set softtabstop=2
set expandtab
set smartindent
set nobackup
set noswapfile
set hlsearch
set incsearch
set ignorecase
set smartcase
set ruler
set novisualbell
set wildmenu
set wildmode=full
set history=200
noremap <Tab> %
" set cc=80
let mapleader = "\<Space>"

" noremap Q g#
" noremap q g*
" noremap q gd

cnoremap <expr> %% getcmdtype( ) == ':' ? expand('%:h').'/' : '%%'

if has("autocmd")
  au BufReadPost * if line("'\"") > 1 && line("'\"") <= line("$") | exe "normal! g'\"" | endif
endif

 " IndentLine
let g:indentLine_enabled = 1
let g:indentLine_concealcursor = 0
" let g:indentLine_char = '┆'
let g:indentLine_faster = 1
let g:indentLine_char_list = ['|', '¦']


cnoreabbrev W! w!
cnoreabbrev Q! q!
cnoreabbrev Qall! qall!
cnoreabbrev Wq wq
cnoreabbrev Wa wa
cnoreabbrev wQ wq
cnoreabbrev WQ wq
cnoreabbrev W w
cnoreabbrev Q q
cnoreabbrev Qall qall

 "" Split
noremap <Leader>h :<C-u>split<CR>
noremap <Leader>v :<C-u>vsplit<CR>

nmap <silent> <F5> :TagbarToggle<CR>
let g:tagbar_autofocus = 1
let g:tagbar_width = 60

nmap <silent> <F6> :NERDTreeToggle<CR>

"" Buffer nav
nnoremap <F11> :bp<CR>
nnoremap <F12> :bn<CR>

"" Vmap for maintain Visual Mode after shifting > and <
vmap < <gv
vmap > >gv

" undotree
map <leader>u :UndotreeToggle<CR>
if has("persistent_undo")
  set undodir=~/.vim/.undodir
  set undofile
endif

" leaderF
let g:Lf_ShortcutF='<C-p>'
noremap <F1> :LeaderfBuffer<CR>
noremap <F2> :LeaderfFunction<CR>
noremap <F3> :LeaderfMru<CR>
noremap <F4> :Leaderf rg<CR>
let g:Lf_CacheDirectory=expand('~/.vim/cache')
let g:Lf_HideHelp=1

" vim-expand-region
map v <Plug>(expand_region_expand)
map <C-c>  <Plug>(expand_region_shrink)

" CompleteParameter
inoremap <silent><expr> ( complete_parameter#pre_complete("()")
smap <c-j> <Plug>(complete_parameter#goto_next_parameter)
imap <c-j> <Plug>(complete_parameter#goto_next_parameter)
smap <c-k> <Plug>(complete_parameter#goto_previous_parameter)
imap <c-k> <Plug>(complete_parameter#goto_previous_parameter)

" airline
let g:airline#extensions#tabline#enabled = 1

" vim-go
let g:go_highlight_types = 1
let g:go_highlight_fields = 1
let g:go_highlight_functions = 1
let g:go_highlight_function_calls = 1
let g:go_highlight_operators = 1
let g:go_highlight_extra_types = 1
let g:go_highlight_build_constraints = 1
let g:go_highlight_generate_tags = 1
let g:go_metalinter_enabled = ['vet', 'golint', 'errcheck']
let g:go_metalinter_autosave = 1
let g:go_metalinter_autosave_enabled = ['vet', 'golint']
let g:go_metalinter_deadline = "5s"
let g:go_list_types = "quickfix"
let g:go_test_timeout = '10s' 
let g:go_fmt_command = "goimports"
let g:go_fmt_autosave = 0

set autowrite

autocmd Filetype go command! -bang A call go#alternate#Switch(<bang>0, 'edit')
autocmd Filetype go command! -bang AV call go#alternate#Switch(<bang>0, 'vsplit')
autocmd Filetype go command! -bang AS call go#alternate#Switch(<bang>0, 'split')
autocmd Filetype go command! -bang AT call go#alternate#Switch(<bang>0, 'tabe')

let g:go_def_mode = 'godef'
let g:go_decls_includes = "func,type"
let g:go_fold_enable = ['block', 'import', 'varconst', 'package_comment']

" run :GoBuild or :GoTestCompile based on the go file
function! s:build_go_files()
  let l:file = expand('%s')
  if l:file =~# '^\f\+_test\.go$'
    call go#test#Test(0,1)
  elseif l:file =~# '^\f\+\.go$'
    call go#cmd#Build(0)
  endif
endfunction

autocmd FileType go nmap <leader>b :<C-u>call <SID>build_go_files()<CR>
autocmd FileType go nmap <leader>0 <Plug>(go-coverage-toggle)

" molokai
let g:rehash256 = 1
let g:molokai_original = 1
colorscheme molokai

" 十字架
set cursorline " cursorcolumn
highlight CursorLine   cterm=reverse ctermbg=NONE ctermfg=NONE guibg=NONE guifg=NONE
" highlight CursorColumn cterm=reverse ctermbg=NONE ctermfg=NONE guibg=NONE guifg=NONE

" nerdcommenter
let g:NERDSpaceDelims=1
let g:NERDCompatSexyComs=1
let g:NERDDefaultAlign='left'
let g:NERDCommentEmptyLines=1
let g:NERDTrimTrailingWhitespace=1

" tagbar
" let g:tagbar_width=80

" md toc
let g:vmt_list_item_char = "-"
noremap <F8> :GenTocGFM<CR>

" git commit
autocmd Filetype gitcommit setlocal spell textwidth=72

" disable arrow key
noremap <Up> <Nop>
noremap <Down> <Nop>
noremap <Left> <Nop>
noremap <Right> <Nop>

inoremap <Up> <Nop>
inoremap <Down> <Nop>
inoremap <Left> <Nop>
inoremap <Right> <Nop>

" cursor maps
nnoremap k gk
nnoremap gk k
nnoremap j gj
nnoremap gj j


" Use deoplete.
let g:deoplete#enable_at_startup = 1
" call deoplete#custom#option('omni_patterns', { 'go': '[^. *\t]\.\w*' })
set encoding=utf-8

" auto save
retab " 打开vim时把已有的Tab全部转换成空格
au InsertLeave *.* write " 每次退出插入模式时自动保存
