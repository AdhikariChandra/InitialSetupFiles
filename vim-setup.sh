#!/bin/bash

# Check if Vim or GVim is installed
if ! command -v vim &> /dev/null && ! command -v gvim &> /dev/null; then
    echo "Vim is not installed."

    read -p "Do you want to install Vim? [y/N] " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        sudo dnf install vim vim-common vim-X11 -y
        echo "Vim installed successfully."
    else
        echo "Installation skipped."
        exit 1
    fi
else
    echo "Vim is already installed."
fi

# Setup vimrc
if [ -f "$HOME/.vimrc" ]; then
    echo "~/.vimrc already exists."
else
    echo "Creating ~/.vimrc..."

    cat << 'EOF' > "$HOME/.vimrc"
syntax on
set number
set clipboard=unnamedplus
set tabstop=4
set shiftwidth=4
set expandtab
EOF

    echo "~/.vimrc created."
fi

exit 0
