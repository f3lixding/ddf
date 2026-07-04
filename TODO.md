# TODO
- [ ] Syntax highlighting
- [ ] Border and custom formatting
- [ ] Optimize SPSC (caching tail / head + false sharing prevention)
- [ ] Refine grapheme width estimation with real notcurses api
- [ ] Streaming api for diff invocation
- [ ] Proper starting args
- [ ] Refine arg sets 

# DONE
- [x] Diff viewer
- [x] Splash screen (this would also be where we come up with layout structure and perhaps refine Component interface)
- [x] Generic, configurable input handler. This is to be reused by different Components
- [x] Main app loop scaffolding
- [x] App rendering loop + abstracting rendering logic
- [x] Logger
- [x] Input parser
- [x] Lockfree implementation of channels with timeout
- [x] Basic arg parsing logic
