# Ratio-Zig
This is a lightnovel TUI that I built in Zig to learn the language so there
are quite a few rough edges since I'm still new to it but for the most part it
works pretty well.

There is no loading state or exposed config yet so there will be 'lag' as it 
fetches data from the page.

# Install

It has been built with zig 0.13.0 so to install you can do:
`zig build -Doptimize=ReleaseFast`

and then copy it somewhere in your path e.g.
`sudo cp zig-out/bin/flow /usr/local/bin`

Or just install it in your home directory:
`zig build -Doptimize=ReleaseFast --prefix ~/.local`

# Usage

These are the current keybinds per `Page`

## Home
```
  [s]       - Go to search page
  [p]       - Prefetches/downloads all the chapters for the selected novel from the currently read chapter
  [d]       - Deletes the novel and all chapters from the database
  [enter]   - Start reading the selected novel from the list
  [esc]     - Quit the app
  [tab]     - Toggle focus between components
```

## Search
```
  [enter]   - When on the input, it will start the search
            - When on the list, it will start reading the selected novel
  [esc]     - Quit the app
  [tab]     - Toggle focus between components
```

### Reader
```
  [j]        - Scroll down by 1 line
  [k]        - Scroll up by 1 line
  [h]        - Go to previous chapter (if > 0)
  [l]        - Go to next chapter (if available)
  [q]        - Quit the app
```
