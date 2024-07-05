# vi.lua
A vi like editor for CC:Tweaked made in about a day by using [edit.lua](https://github.com/cc-tweaked/CC-Tweaked/blob/mc-1.20.x/projects/core/src/main/resources/data/computercraft/lua/rom/programs/edit.lua) as a base.

![image](https://github.com/Walcriz/cctweaked-vi/assets/68862100/72346e68-04a1-4922-8b2a-12ff9544a9bb)

## Installation
To install run this command in your CC:Tweaked computer
```
pastebin get 6NMvc2dB vi.lua
```

To then open the editor
```
/vi <file-path>
```

## Features
- A vi like control scheme for editing files in CC:Tweaked
- Clipboard function
- Undo/Redo
- And a bit more!

## Limitations
- To exit `INSERT` mode `CTRL+C` must be used in place of `ESC` since that would just close the gui
- Commands like `w` `b` and `e` are not really correcly implemented (though only for repeating `.` `-` etc.), if you are an experienced vim user this may be noticable
- No VISUAL mode exists (traces of an implementation exists though, contributions are welcome)
- Commands like `f` and `t` are not implemented (a list of commands can be found in source [here](https://github.com/Walcriz/cctweaked-vi/blob/e2baf9316d827d23e6bb87e09a60818d0df6120a/vi.lua#L994))

## Credits
- The original CC:Tweaked [edit.lua](https://github.com/cc-tweaked/CC-Tweaked/blob/mc-1.20.x/projects/core/src/main/resources/data/computercraft/lua/rom/programs/edit.lua)
