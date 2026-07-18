# TODO
- [ ] Add line number
- [ ] Refine arg sets 
- [ ] Put file and lines deleted / added on top line of border
- [ ] Optimize SPSC (caching tail / head + false sharing prevention)
- [ ] File picker (but only for files changed)
- [ ] Refine grapheme width estimation with real notcurses api
- [ ] Streaming api for diff invocation
- [ ] Proper starting args

# DONE
- [x] Cursor (this would probably need to be a subcomponent within diff view)
- [x] Border and custom formatting
- [x] Syntax highlight style application
- [x] Fix coreLoop choosing either key handling _or_ tick (it should do both when applicable)
- [x] Terminate keymap stack eval early on diff viewer
- [x] Syntax highlighting
- [x] Diff viewer
- [x] Splash screen (this would also be where we come up with layout structure and perhaps refine Component interface)
- [x] Generic, configurable input handler. This is to be reused by different Components
- [x] Main app loop scaffolding
- [x] App rendering loop + abstracting rendering logic
- [x] Logger
- [x] Input parser
- [x] Lockfree implementation of channels with timeout
- [x] Basic arg parsing logic
