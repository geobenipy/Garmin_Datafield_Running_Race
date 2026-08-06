import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// ---------------------------------------------------------------------------
// On-watch race setup  –  what AppBase.getSettingsView() hands back
// ---------------------------------------------------------------------------
// A data field may not take input while it is drawing, so this is the one
// sanctioned way to configure one from the wrist: the system pushes this menu
// itself, from the activity menu, and only ever outside the draw path.  The
// running field never sees these views — it picks the change up at its next
// heavy refresh through RaceSetup.dirty.
//
//   Renn-Setup ─┬─ Distanz   → preset list (+ "Eigene ..." → adjuster, 100 m)
//               ├─ Ziel-Pace → adjuster, 5 s/km steps
//               ├─ Zielzeit  → adjuster, 1 min steps  (back-computes the pace)
//               └─ Toleranz  → adjuster, 5 s/km steps
//
// Zielzeit is not a fourth stored setting; it is pace x distance seen from the
// other end.  Every sub-label is therefore rebuilt after any change (see
// RaceSettingsMenu.refresh) — editing the pace has to move the time under it.
//
// The adjuster is one view for all four values: RaceSetup owns the title, the
// step size, the clamp and the formatting per field, so adding a fifth value
// means adding a case there, not another view here.
// ---------------------------------------------------------------------------

class RaceSettingsMenu extends WatchUi.Menu2 {

    var distanceItem  as WatchUi.MenuItem;
    var paceItem      as WatchUi.MenuItem;
    var timeItem      as WatchUi.MenuItem;
    var toleranceItem as WatchUi.MenuItem;

    function initialize() {
        Menu2.initialize({:title => "Renn-Setup"});

        distanceItem  = new WatchUi.MenuItem("Distanz",   "", RaceSetup.FIELD_DISTANCE,  null);
        paceItem      = new WatchUi.MenuItem("Ziel-Pace", "", RaceSetup.FIELD_PACE,      null);
        timeItem      = new WatchUi.MenuItem("Zielzeit",  "", RaceSetup.FIELD_TIME,      null);
        toleranceItem = new WatchUi.MenuItem("Toleranz",  "", RaceSetup.FIELD_TOLERANCE, null);

        addItem(distanceItem);
        addItem(paceItem);
        addItem(timeItem);
        addItem(toleranceItem);
        refresh();
    }

    // Re-read every line from the stored settings.  Called after any edit
    // because the four lines are only three independent numbers: a new pace or
    // a new distance both move the target time.
    function refresh() as Void {
        distanceItem.setSubLabel(RaceSetup.formatDistance(RaceSetup.distanceM()));
        paceItem.setSubLabel(RaceSetup.formatPace(RaceSetup.paceSec()) + " /km");
        timeItem.setSubLabel(RaceSetup.formatTime(RaceSetup.targetTimeSec()));
        toleranceItem.setSubLabel("+/- " + RaceSetup.toleranceSec().format("%d") + " s/km");
        WatchUi.requestUpdate();
    }
}

class RaceSettingsMenuDelegate extends WatchUi.Menu2InputDelegate {

    var menu as RaceSettingsMenu;

    function initialize(menuRef as RaceSettingsMenu) {
        Menu2InputDelegate.initialize();
        menu = menuRef;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof Lang.Number)) { return; }

        if (id == RaceSetup.FIELD_DISTANCE) {
            // Distance is the one value where stepping from a marathon to a
            // 10 km would be 320 button presses, so it gets a preset list.
            var distanceMenu = new RaceDistanceMenu();
            WatchUi.pushView(distanceMenu,
                             new RaceDistanceMenuDelegate(menu),
                             WatchUi.SLIDE_LEFT);
            return;
        }
        pushAdjuster(id as Number, menu);
    }
}

// ---------------------------------------------------------------------------
// Distance preset list
// ---------------------------------------------------------------------------
// Item ids are the distance in metres, so the delegate needs no lookup table.
// -1 is the odd one out: "Eigene ..." opens the adjuster on the current value.

class RaceDistanceMenu extends WatchUi.Menu2 {

    const ID_CUSTOM = -1;

    function initialize() {
        Menu2.initialize({:title => "Distanz"});
        addPreset("5 km",          5000);
        addPreset("10 km",         10000);
        addPreset("15 km",         15000);
        addPreset("Halbmarathon",  21098);
        addPreset("25 km",         25000);
        addPreset("30 km",         30000);
        addPreset("Marathon",      42195);
        addPreset("50 km",         50000);
        addItem(new WatchUi.MenuItem("Eigene ...", "100 m Schritte",
                                     ID_CUSTOM, null));
    }

    function addPreset(label as String, meters as Number) as Void {
        addItem(new WatchUi.MenuItem(label, RaceSetup.formatDistance(meters),
                                     meters, null));
    }
}

class RaceDistanceMenuDelegate extends WatchUi.Menu2InputDelegate {

    var parentMenu as RaceSettingsMenu;

    function initialize(parent as RaceSettingsMenu) {
        Menu2InputDelegate.initialize();
        parentMenu = parent;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof Lang.Number)) { return; }

        if (id > 0) {
            RaceSetup.setDistanceM(id as Number);
            parentMenu.refresh();
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
            return;
        }
        pushAdjuster(RaceSetup.FIELD_DISTANCE, parentMenu);
    }
}

// ---------------------------------------------------------------------------
// The adjuster: one view, any of the four values
// ---------------------------------------------------------------------------

function pushAdjuster(field as Number, parent as RaceSettingsMenu) as Void {
    var view = new RaceAdjustView(field);
    WatchUi.pushView(view, new RaceAdjustDelegate(view, parent), WatchUi.SLIDE_LEFT);
}

class RaceAdjustView extends WatchUi.View {

    const COLOR_BG    = 0x060606;
    const COLOR_WHITE = 0xF4F4F4;
    const COLOR_MUTED = 0x8E949B;
    const COLOR_BLUE  = 0x63C6F5;

    var field as Number;
    var value as Number;     // live edit value, only written back on select

    function initialize(fieldId as Number) {
        View.initialize();
        field = fieldId;
        value = RaceSetup.fieldValue(fieldId);
    }

    function onUpdate(dc as Dc) as Void {
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;

        dc.setColor(COLOR_BG, COLOR_BG);
        dc.clear();

        text(dc, cx, (h * 26) / 100, RaceSetup.fieldTitle(field),
             Graphics.FONT_SMALL, COLOR_MUTED);
        text(dc, cx, cy, RaceSetup.fieldText(field, value),
             Graphics.FONT_NUMBER_MILD, COLOR_WHITE);
        text(dc, cx, cy + ((h * 13) / 100), RaceSetup.fieldUnit(field),
             Graphics.FONT_XTINY, COLOR_MUTED);

        // Chevrons rather than a "+/-" label: they say which key does what
        // without needing a language, and they are drawn from primitives so no
        // font can render them as garbage.
        chevron(dc, cx, (h * 38) / 100, w / 26,  1);
        chevron(dc, cx, (h * 62) / 100, w / 26, -1);

        text(dc, cx, (h * 76) / 100, "START = OK", Graphics.FONT_XTINY, COLOR_BLUE);
    }

    // direction is +1 (up) or -1 (down).
    function change(direction as Number) as Void {
        value = RaceSetup.fieldStep(field, value, direction);
        WatchUi.requestUpdate();
    }

    function save() as Void {
        RaceSetup.applyField(field, value);
    }

    function text(dc as Dc, cx as Number, cy as Number, str as String,
                  font as Graphics.FontType, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy, font, str,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    function chevron(dc as Dc, cx as Number, cy as Number,
                     halfW as Number, direction as Number) as Void {
        var halfH = halfW - (halfW / 3);
        dc.setColor(COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
        if (direction > 0) {
            dc.fillPolygon([[cx, cy - halfH],
                            [cx - halfW, cy + halfH],
                            [cx + halfW, cy + halfH]]);
        } else {
            dc.fillPolygon([[cx, cy + halfH],
                            [cx - halfW, cy - halfH],
                            [cx + halfW, cy - halfH]]);
        }
    }
}

class RaceAdjustDelegate extends WatchUi.BehaviorDelegate {

    var view   as RaceAdjustView;
    var parent as RaceSettingsMenu;

    function initialize(viewRef as RaceAdjustView, parentRef as RaceSettingsMenu) {
        BehaviorDelegate.initialize();
        view   = viewRef;
        parent = parentRef;
    }

    // UP / DOWN keys, and the equivalent swipes on a touch screen.
    function onPreviousPage() as Boolean { view.change( 1); return true; }
    function onNextPage()     as Boolean { view.change(-1); return true; }

    // START confirms and writes.  BACK is deliberately left to the default
    // pop, which discards — so a mis-scroll on the start line costs nothing.
    function onSelect() as Boolean {
        view.save();
        parent.refresh();
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }

    // Touch: top half of the face steps up, bottom half steps down.  The keys
    // are the primary path; this just means the fenix 8's screen is not dead.
    function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        var coords = clickEvent.getCoordinates();
        if (coords == null || coords.size() < 2) { return false; }
        var y = coords[1] as Number;
        if (y < System.getDeviceSettings().screenHeight / 2) {
            view.change(1);
        } else {
            view.change(-1);
        }
        return true;
    }
}
