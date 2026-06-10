pub const c = @cImport({
    @cInclude("locale.h");
    @cInclude("stdio.h");
    @cInclude("time.h");
    @cInclude("notcurses/notcurses.h");
    @cInclude("notcurses/direct.h");
});
