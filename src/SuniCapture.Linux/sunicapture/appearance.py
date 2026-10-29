"""Application surfaces, compact controls and readable GTK popup menus."""


def css(dark):
    colors = dict(chrome="#191E2E" if dark else "#F8FAFC", surface="#22283A" if dark else "#FFFFFF",
                  border="#343C52" if dark else "#E2E8F0", text="#F1F5F9" if dark else "#0F172A",
                  muted="#A5B4CA" if dark else "#64748B", soft="#2C3C59" if dark else "#E9EFFD",
                  hover="#2A3648" if dark else "#EEF2F7", canvas="#0B101A" if dark else "#E5E7EB",
                  selected="#9DBBFF" if dark else "#1D4ED8")
    definitions = "\n".join("@define-color capture_" + key + " " + value + ";" for key, value in colors.items())
    return definitions + """
    .capture-window, .capture-dialog {
        background: @capture_chrome; color: @capture_text;
        font-family: "DejaVu Sans", sans-serif; font-size: 13px;
    }
    .capture-content, .capture-dialog-content { color: @capture_text; }
    .capture-window decoration, .capture-dialog decoration {
        background: @capture_surface; border: 1px solid @capture_border; box-shadow: none;
    }
    .capture-content label, .capture-dialog-content label, .capture-titlebar label { color: inherit; }
    .capture-content label.muted, .capture-dialog-content label.muted { color: @capture_muted; }
    .surface, .sidebar { background: @capture_surface; }
    .sidebar { border-right: 1px solid @capture_border; }
    .canvas { background: @capture_canvas; }
    .toolbar { background: @capture_surface; border-bottom: 1px solid @capture_border; padding: 8px 16px; }
    .status { border-top: 1px solid @capture_border; padding: 5px 16px; }
    button.capture-action {
        min-height: 20px; min-width: 16px; padding: 5px 10px;
        background-image: none; background-color: @capture_surface; color: @capture_text;
        border: 1px solid @capture_border; border-radius: 6px; box-shadow: none; text-shadow: none;
    }
    button.capture-action:hover { background: @capture_hover; border-color: #9AAAC2; }
    button.capture-action:focus { outline: 2px solid #2563EB; outline-offset: -2px; }
    button.capture-action:disabled { opacity: .45; }
    button.capture-action label { color: inherit; }
    button.capture-action.primary { background: #2563EB; color: white; border-color: #2563EB; font-weight: bold; }
    button.capture-action.primary:hover { background: #1D4ED8; }
    button.capture-action.danger { background: #DC2626; color: white; border-color: #DC2626; }
    button.capture-action.quiet { background: transparent; border-color: transparent; }
    button.capture-action.quiet:hover { background: @capture_hover; }
    button.capture-action.nav { background: transparent; border-color: transparent; padding: 7px 10px; }
    button.capture-action.nav:hover { background: @capture_hover; }
    button.capture-action.selected { background: @capture_soft; border-color: @capture_soft; color: @capture_selected; }
    button.capture-action.tool { min-width: 18px; min-height: 18px; padding: 6px; }
    button.capture-action.icon-button { min-width: 18px; min-height: 18px; padding: 6px; }
    headerbar.capture-titlebar {
        min-height: 32px; padding: 5px 8px; background: @capture_surface;
        background-image: none; color: @capture_text; border: 0; border-bottom: 1px solid @capture_border;
        box-shadow: none;
    }
    headerbar.capture-titlebar .title { font-size: 13px; font-weight: bold; color: @capture_text; }
    headerbar.capture-titlebar button.titlebutton {
        min-width: 28px; min-height: 28px; padding: 0; margin: 0 2px;
        background: transparent; background-image: none; color: @capture_text;
        border: 0; border-radius: 5px; box-shadow: none;
    }
    headerbar.capture-titlebar button.titlebutton:hover { background: @capture_hover; }
    headerbar.capture-titlebar button.titlebutton.close:hover { background: #DC2626; color: white; }
    headerbar.capture-titlebar button.titlebutton:focus { outline: 2px solid #2563EB; outline-offset: -2px; }
    headerbar.capture-titlebar separator { background: @capture_border; margin: 5px 6px; }
    .capture-content entry, .capture-dialog-content entry {
        min-height: 20px; padding: 6px 9px; background: @capture_surface;
        color: @capture_text; border: 1px solid @capture_border; border-radius: 6px;
        caret-color: #2563EB; box-shadow: none;
    }
    .capture-content entry:focus, .capture-dialog-content entry:focus { border-color: #2563EB; }
    .capture-content combobox button, .capture-dialog-content combobox button {
        min-height: 20px; padding: 5px 9px; background: @capture_surface; background-image: none;
        color: @capture_text; border: 1px solid @capture_border; border-radius: 6px; box-shadow: none;
    }
    .capture-content combobox arrow, .capture-dialog-content combobox arrow { color: @capture_muted; }
    .capture-content list, .capture-content row { background: @capture_surface; color: @capture_text; }
    .capture-content row { border-radius: 6px; margin: 2px 0; padding: 8px; }
    .capture-content row:selected { background: @capture_soft; }
    menu, .capture-menu { background: @capture_surface; color: @capture_text; padding: 5px; border: 1px solid @capture_border; }
    menu menuitem { min-height: 22px; padding: 5px 12px; color: @capture_text; border-radius: 4px; }
    menu menuitem label { color: inherit; }
    menu menuitem:hover { background: @capture_soft; color: @capture_text; }
    menu menuitem:disabled { color: @capture_muted; }
    menu check, menu radio { color: #2563EB; }
    .capture-dialog .dialog-action-area { border-top: 1px solid @capture_border; padding: 12px 18px; }
    .capture-dialog .dialog-action-area button { margin-left: 6px; }
    .card { background: @capture_surface; border: 1px solid @capture_border; border-radius: 9px; padding: 20px; }
    .privacy { background: @capture_soft; border: 1px solid @capture_border; border-radius: 8px; padding: 16px; }
    .badge { background: @capture_soft; border-radius: 12px; padding: 5px 10px; font-size: 11px; }
    .section { border-top: 1px solid @capture_border; padding-top: 16px; margin-top: 14px; }
    .capture-content separator, .capture-dialog-content separator { background: @capture_border; }
    """
