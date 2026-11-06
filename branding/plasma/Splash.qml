import QtQuick

Rectangle {
    id: root
    color: "#000000"
    property int stage

    Image {
        anchors.centerIn: parent
        source: "images/zaviya.svg"
        sourceSize.height: root.height * 0.5
    }
}
