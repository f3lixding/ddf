# TODO
- [ ] Terminate keymap stack eval early on diff viewer
- [ ] Fix coreLoop choosing either key handling _or_ tick (it should do both when applicable)
- [ ] Border and custom formatting
- [ ] Optimize SPSC (caching tail / head + false sharing prevention)
- [ ] Refine grapheme width estimation with real notcurses api
- [ ] Streaming api for diff invocation
- [ ] Proper starting args
- [ ] Refine arg sets 

# DONE
- [x] Clean up splash screen on new component mount (this requires adding two new methods on the Component interface)
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
