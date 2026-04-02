import Toybox.Graphics;
import Toybox.WatchUi;

class Running_RaceBackground extends WatchUi.Drawable {

    function initialize() {
        Drawable.initialize({ :identifier => "Background" });
    }

    function draw(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_BLACK);
        dc.clear();
    }
}
