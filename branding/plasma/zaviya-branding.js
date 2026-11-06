// Runs once per user. Moves existing desktops off the old wallpaper and menu
// icon, and leaves anything the user picked themselves.
var all = desktops();
for (var i = 0; i < all.length; i++) {
    var d = all[i];
    if (d.wallpaperPlugin !== "org.kde.image")
        continue;
    d.currentConfigGroup = ["Wallpaper", "org.kde.image", "General"];
    var image = d.readConfig("Image", "");
    if (image === "" || image.indexOf("Steam Deck Logo") !== -1)
        d.writeConfig("Image", "/usr/share/wallpapers/Zaviya");
}
var bars = panels();
for (var p = 0; p < bars.length; p++) {
    var widgets = bars[p].widgets("org.kde.plasma.kickoff");
    for (var w = 0; w < widgets.length; w++) {
        widgets[w].currentConfigGroup = ["General"];
        if (widgets[w].readConfig("icon", "") === "distributor-logo-steamdeck")
            widgets[w].writeConfig("icon", "zaviya-mark");
    }
}
