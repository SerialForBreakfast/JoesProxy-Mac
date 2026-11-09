//
//  PlayerView.swift
//  JoesProxyPlayer
//
/// AVPlayerLayer bridge for SwiftUI. The player instance is owned by `PlaybackSessionController`.
///

import AVFoundation
import SwiftUI
import UIKit

/// Embeds an `AVPlayer` in SwiftUI via `AVPlayerLayer`.
struct PlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}

/// UIKit host that keeps `AVPlayerLayer` sized to its bounds.
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            preconditionFailure("PlayerUIView requires AVPlayerLayer as its layer class")
        }
        return playerLayer
    }
}
