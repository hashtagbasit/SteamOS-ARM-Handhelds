// Bottom screen UI. Backend: ../dashboard (see Ui.qml).
//
// Pages: home (tools and apps), dash (stats and quick controls), pad/keys
// (the top screen's trackpad and keyboard), settings, apps (pick what the
// home screen shows). The backend can send the UI to a page (AYN button,
// swipe up from the bottom edge): it bumps nav.serial and the UI follows.
//
// Polling: /nav (cheap: page, app rows, bottom screen on/off) every 0.4 s so
// the AYN button answers at once; /state (all the stats) once a second, only
// while the dashboard is on screen.
//
// qml6 Main.qml -- [--shot out.png WxH [page]] api-file: save a picture of
// the UI and quit (layout checks without the device).
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Window {
    id: root
    title: "SteamOS Bottom Screen"
    visible: true
    visibility: Window.FullScreen
    // Start at the screen's size so the first frame is already laid out.
    width: Screen.width > 0 ? Screen.width : 1240
    height: Screen.height > 0 ? Screen.height : 1080
    color: Ui.bg

    property string page: "home"
    property int navSerial: -1
    property var nav: ({})
    property var running: []
    property var pinned: []
    property var web: []
    property var hub: []
    property var recent: []
    function pollRecent() { Ui.request("GET", "/recent", undefined, function (r) { if (r && r.games) root.recent = r.games }) }
    function pollHub() { Ui.request("GET", "/hub", undefined, function (r) { if (r && r.apps) root.hub = r.apps }) }
    property bool bottomOn: true
    property string rowsKey: ""
    property string shotFile: ""
    property bool demo: false

    Binding { target: Ui; property: "s"; value: Math.min(root.width / 1240, root.height / 1080) }

    function go(p) {
        if (p === page)
            return
        page = p
        Ui.post("/nav", { page: p })
        if (p === "dash")
            pollState()
    }
    function pollNav() {
        Ui.request("GET", "/nav", undefined, function (n) {
            if (!n)
                return
            nav = n.nav || ({})
            bottomOn = n.bottom_on !== false
            if (nav.serial !== undefined && nav.serial !== navSerial && root.shotFile === "") {
                navSerial = nav.serial
                if (nav.page)
                    page = nav.page
                if (page === "dash")
                    pollState()
            }
            // Only hand the tiles a new model when the apps changed.
            var key = JSON.stringify([n.running || [], n.pinned || [], n.web || []])
            if (key !== rowsKey) {
                rowsKey = key
                running = n.running || []
                web = n.web || []
                pinned = (n.pinned || []).filter(function (p) {
                    return !(n.running || []).some(function (r) { return r.id === p.id })
                })
            }
        })
    }
    function pollState() {
        Ui.request("GET", "/state", undefined, function (n) {
            if (!n || n.hidden)
                return
            if (root.shotFile !== "" && !(n.sessions && n.sessions.length)) {   // screenshots: a play log
                var e = Date.now() / 1000
                var lc = "/home/steamos/.local/share/Steam/appcache/librarycache/"
                n.sessions = [{ appid: 1546970, name: "Grand Theft Auto III", minutes: 47, wh: 5.4, fps: 55, end: e - 2400, cover: lc + "1546970/library_600x900.jpg" },
                              { appid: 631510, name: "Devil May Cry HD Collection", minutes: 82, wh: 7.9, fps: 60, end: e - 26000, cover: lc + "631510/library_600x900.jpg" },
                              { appid: 1546990, name: "Grand Theft Auto: Vice City", minutes: 35, wh: 4.6, fps: 58, end: e - 95000, cover: lc + "1546990/library_600x900.jpg" }]
            }
            if (root.demo) {               // screenshots of a game in progress
                var t = Date.now() / 1000
                n.fps = Math.round(58 + 3 * Math.sin(t / 3))
                var gl = "/home/steamos/.local/share/Steam/appcache/librarycache/1546970/"
                n.game = { appid: 1546970, name: "Grand Theft Auto III", remembered: true,
                           art: { hero: gl + "library_hero.jpg", logo: gl + "logo.png", cover: gl + "library_600x900.jpg", blur: gl + "library_hero_blur.jpg" } }
                n.fg = { multiplier: 2, flow: 0.5, profile: true }
                n.power_w = -(7.2 + 0.8 * Math.sin(t / 5))
                n.cpu = { ghz: 2.4, load: 46 }; n.gpu = { mhz: 680, max_mhz: 1050 }
                n.temps = { cpu: 63, gpu: 58, hot: 64 }
                n.refresh = { rates: [60, 90, 120, 144], choice: 0 }
            }
            Ui.st = n
            dashPage.pushFps(n.fps)
            dashPage.pushStats(n)
            if (root.demo && dashPage.energyWh < 1) { dashPage.sessionStart = Date.now() - 47 * 60000; dashPage.energyWh = 5.4 }
        })
    }
    Connections {
        target: Ui
        function onChanged() { root.pollNav(); if (root.page === "dash" || root.page === "settings" || root.page === "home") root.pollState() }
    }
    Timer { interval: 400; running: root.shotFile === ""; repeat: true; onTriggered: root.pollNav() }
    // One-tap app tiles on home: their install state, every few seconds.
    Timer { interval: 4000; running: root.page === "home"; repeat: true; triggeredOnStart: true; onTriggered: root.pollHub() }
    Timer { interval: 30000; running: root.page === "home"; repeat: true; triggeredOnStart: true; onTriggered: root.pollRecent() }
    // Home shows the toggles and the game in front: refresh those gently.
    Timer { interval: 3000; running: root.page === "home" && root.shotFile === ""; repeat: true; onTriggered: root.pollState() }
    Timer {
        interval: 1000
        running: (root.page === "dash" || root.page === "skins") && root.shotFile === ""
        repeat: true
        onTriggered: root.pollState()
    }

    // The dashboard opened over an app steps back to it after a while
    // without a touch (Settings).
    Timer {
        id: idle
        interval: Math.max(1, Ui.cfg.dash_idle_s || 0) * 1000
        running: root.page === "dash" && (Ui.cfg.dash_idle_s || 0) > 0 && !!root.nav.under
        onTriggered: Ui.post("/dash-done")
    }
    // Any touch anywhere keeps the dashboard up (passive: takes nothing).
    Item {
        anchors.fill: parent
        z: 100
        PointHandler {
            onActiveChanged: if (active && idle.running) idle.restart()
        }
    }

    Timer {
        id: shotTimer
        interval: 2500
        onTriggered: root.contentItem.grabToImage(function (r) { r.saveToFile(root.shotFile); Qt.quit() })
    }
    Component.onCompleted: {
        var args = Qt.application.arguments
        var si = args.indexOf("--shot")
        if (si >= 0) {
            shotFile = args[si + 1]
            var wh = args[si + 2].split("x")
            root.visibility = Window.Windowed
            root.width = parseInt(wh[0])
            root.height = parseInt(wh[1])
            if (args[si + 3] && args[si + 3].indexOf("/") < 0)
                page = args[si + 3]
            if (page.indexOf("@") > 0) { dashPage.shotSkin = page.split("@")[1]; page = page.split("@")[0] }
            if (page === "dashplay") { page = "dash"; demo = true }
            if (page === "homeplay") { page = "home"; demo = true }
            if (page === "opening") { page = "home"; Ui.launching = { name: "YouTube", icon: "media-playback-start-symbolic", web: true } }
            if (page.indexOf("skin-") === 0) { dashPage.shotSkin = page.slice(5); page = "dash"; demo = true }
            for (var i = 0; i < 58; i++) {   // a minute of history for the picture
                dashPage.pushFps(Math.round(55 + 5 * Math.sin(i / 4) - (i % 17 === 0 ? 14 : 0)))
                dashPage.pushStats({ cpu: { load: 40 + 15 * Math.sin(i / 6) }, gpu: { mhz: 600 + 120 * Math.sin(i / 5), max_mhz: 1050 },
                                     power_w: -(6.5 + 1.5 * Math.sin(i / 7)), temps: { hot: 58 + i / 10 } }, true)
            }
            shotTimer.start()
        }
        Ui.loadApi(args[args.length - 1], function () {
            if (dashPage.shotSkin)
                Ui.request("GET", "/skins", undefined, function (r) {
                    var k = (r && r.skins || []).filter(function (x) { return x.id === dashPage.shotSkin })[0]
                    Ui.shotColors = k && Object.keys(k.colors || {}).length ? k.colors : null
                })
            root.pollNav()
            root.pollState()
            root.pollHub()
            root.pollRecent()
        })
    }

    readonly property var titles: ({
        home: "", dash: "Dashboard", pad: "Trackpad and keyboard", keys: "Trackpad and keyboard",
        settings: "Settings", apps: "Apps", notes: "Game Notes", newweb: "Web apps", hub: "Zaviya Loadout", skins: "Theme", bricks: "Bricks"
    })

    // ------------------------------------------------------------- frame --
    // A soft light from the top so the cards sit in a space, not on black.
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0; color: Ui.bgTop }
            GradientStop { position: 0.55; color: Ui.bg }
        }
    }
    Item {
        anchors.fill: parent
        anchors.margins: 24 * Ui.s

        // Status bar: home button (off the home screen), title, clock, battery.
        // On the dashboard it is a slim strip so the readings get the room:
        // home and Steam buttons on the left, time and battery right. The
        // buttons stay big enough to hit on a 4" screen.
        readonly property bool slim: root.page === "dash"
        RowLayout {
            id: status
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: (parent.slim ? 76 : 72) * Ui.s
            spacing: (parent.slim ? 16 : 24) * Ui.s
            Btn {
                visible: root.page !== "home"
                Layout.preferredWidth: (status.parent.slim ? 76 : 160) * Ui.s
                Layout.preferredHeight: (status.parent.slim ? 76 : 68) * Ui.s
                label: status.parent.slim ? "" : "⌂ Home"
                icon: status.parent.slim ? "go-home-symbolic" : ""
                iconSize: status.parent.slim ? 36 : 26
                fontSize: 26
                onClicked: root.go("home")
            }
            Txt {
                visible: !status.parent.slim
                text: root.titles[root.page] || ""
                font.pixelSize: 32 * Ui.s
                font.weight: Font.DemiBold
                color: Ui.dim
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
            // Steam's buttons, on the dashboard (Game Mode only).
            Repeater {
                model: root.page === "dash" && !Ui.st.desktop ? [
                    ["steam", "applications-games-symbolic"], ["qam", "view-more-horizontal-symbolic"],
                    ["keyboard", "input-keyboard-virtual-symbolic"], ["screenshot", "camera-photo-symbolic"]] : []
                Btn {
                    required property var modelData
                    Layout.preferredWidth: 76 * Ui.s
                    Layout.preferredHeight: 76 * Ui.s
                    icon: modelData[1]
                    iconSize: 36
                    onClicked: Ui.post("/steam/" + modelData[0])
                }
            }
            Item { Layout.fillWidth: true; visible: status.parent.slim }
            Txt { text: Qt.formatTime(clock.now, "hh:mm"); font.pixelSize: (status.parent.slim ? 32 : 36) * Ui.s; font.weight: Font.Bold }
            Txt {
                readonly property var b: Ui.st.battery
                visible: b !== undefined && b.percent >= 0
                text: b ? (b.status === "Charging" ? "⚡ " : "") + b.percent + "%" : ""
                color: b && b.percent < 15 ? Ui.warn : (status.parent.slim ? Ui.dim : Ui.text)
                font.pixelSize: (status.parent.slim ? 30 : 34) * Ui.s
                font.weight: Font.Bold
            }
        }
        QtObject {
            id: clock
            property date now: new Date()
        }
        Timer { interval: 15000; running: true; repeat: true; triggeredOnStart: true; onTriggered: { clock.now = new Date(); if (root.page !== "dash") root.pollStateLight() } }

        Item {
            id: pages
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: status.bottom
            anchors.topMargin: (status.parent.slim ? 14 : 18) * Ui.s
            anchors.bottom: parent.bottom

            HomePage {
                anchors.fill: parent
                visible: root.page === "home"
                running: root.running
                pinned: root.pinned
                web: root.web
                hub: root.hub
                recent: root.recent
                onOpen: function (p) { root.go(p) }
            }
            DashPage {
                id: dashPage
                anchors.fill: parent
                visible: root.page === "dash"
            }
            RemotePad {
                anchors.fill: parent
                visible: root.page === "pad" || root.page === "keys"
                mode: root.page === "keys" ? "keys" : "pad"
            }
            SkinsPage {
                anchors.fill: parent
                visible: root.page === "skins"
                dash: dashPage
            }
            SettingsPage {
                anchors.fill: parent
                visible: root.page === "settings"
                onOpen: function (p) { root.go(p) }
            }
            BricksPage {
                anchors.fill: parent
                visible: root.page === "bricks"
            }
            HubPage {
                anchors.fill: parent
                visible: root.page === "hub"
            }
            NotesPage {
                anchors.fill: parent
                visible: root.page === "notes"
            }
            NewWebPage {
                anchors.fill: parent
                visible: root.page === "newweb"
                onDone: root.go("home")
            }
            PickerPage {
                anchors.fill: parent
                visible: root.page === "apps"
                onDone: root.go("home")
            }
        }
    }
    // The battery in the status bar off the dashboard: a /state every 15 s.
    function pollStateLight() { pollState() }

    // Bottom screen switched off: black, and the first touch turns it on.
    Rectangle {
        anchors.fill: parent
        visible: !root.bottomOn
        color: "black"
        z: 200
        TapHandler { onTapped: Ui.post("/brightness", { bottom_on: true }) }
    }
    // ------------------------------------------------------ app cover --
    // While a launched app starts, its icon and name instead of a frozen
    // launcher. The app's window comes up over this, so it simply ends up
    // behind; it clears itself a few seconds later either way.
    Rectangle {
        id: cover
        anchors.fill: parent
        z: 150
        visible: opacity > 0
        opacity: Ui.launching ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
        gradient: Gradient {
            GradientStop { position: 0; color: Ui.bgTop }
            GradientStop { position: 1; color: Ui.bg }
        }
        onOpacityChanged: if (opacity === 1) coverClear.restart()
        Timer { id: coverClear; interval: 6000; onTriggered: Ui.launching = null }
        TapHandler { onTapped: Ui.launching = null }
        Column {
            anchors.centerIn: parent
            spacing: 26 * Ui.s
            Rectangle {
                id: badge
                anchors.horizontalCenter: parent.horizontalCenter
                width: 190 * Ui.s; height: width; radius: width * 0.27
                color: Ui.cardHi
                border.color: Ui.cardEdge
                SequentialAnimation on scale {
                    running: cover.visible; loops: Animation.Infinite
                    NumberAnimation { to: 1.05; duration: 650; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0; duration: 650; easing.type: Easing.InOutSine }
                }
                Image {
                    id: coverPic
                    anchors.centerIn: parent
                    width: 120 * Ui.s; height: width
                    source: Ui.launching && Ui.launching.image ? "file://" + Ui.launching.image : ""
                    sourceSize: Qt.size(240, 240)
                    fillMode: Image.PreserveAspectFit
                    visible: status === Image.Ready
                }
                Kirigami.Icon {
                    anchors.centerIn: parent
                    width: 110 * Ui.s; height: width
                    visible: !coverPic.visible
                    source: Ui.launching ? Ui.launching.icon : ""
                    fallback: "application-x-executable"
                    isMask: !!(Ui.launching && (Ui.launching.web || (Ui.launching.icon || "").endsWith("-symbolic")))
                    color: Ui.accent
                }
            }
            Txt {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Ui.launching ? Ui.launching.name : ""
                font.pixelSize: 36 * Ui.s
                font.weight: Font.Bold
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 12 * Ui.s
                Repeater {
                    model: 3
                    Rectangle {
                        required property int index
                        width: 14 * Ui.s; height: width; radius: width / 2
                        color: Ui.accent
                        SequentialAnimation on opacity {
                            running: cover.visible; loops: Animation.Infinite
                            PauseAnimation { duration: index * 160 }
                            NumberAnimation { from: 0.25; to: 1; duration: 320 }
                            NumberAnimation { from: 1; to: 0.25; duration: 320 }
                            PauseAnimation { duration: (2 - index) * 160 }
                        }
                    }
                }
            }
        }
    }
}
