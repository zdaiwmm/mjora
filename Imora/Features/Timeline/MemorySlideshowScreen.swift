import AVFoundation
import SwiftUI

struct MemorySlideshowScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let memory: Memory
    @State private var playback: MemorySlideshowPlayback
    @State private var showsControls = true
    @State private var hideControlsTask: Task<Void, Never>?

    init(memory: Memory) {
        self.memory = memory
        _playback = State(initialValue: MemorySlideshowPlayback(assets: memory.playableAssets))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geometry in
                ZStack {
                    if let frame = playback.frame {
                        ZStack {
                            Image(uiImage: frame.image).resizable().scaledToFit()
                            if let player = frame.video {
                                VideoPlayerSurface(player: player) { playback.videoReady(id: frame.id) }
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .id(frame.id)
                        .transition(.opacity)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: playback.frame?.id)
                .contentShape(.rect)
                .onTapGesture { setControls(!showsControls) }
                .gesture(DragGesture(minimumDistance: 30).onEnded { gesture in
                    guard abs(gesture.translation.width) > abs(gesture.translation.height) else { return }
                    playback.select(playback.index + (gesture.translation.width < 0 ? 1 : -1))
                    setControls(true)
                })
            }
            .ignoresSafeArea()

            if playback.isLoading {
                ProgressView().tint(.white).allowsHitTesting(false)
            }
            if let error = playback.errorMessage {
                VStack(spacing: 14) {
                    Text(error).font(.headline)
                    Button("Retry", systemImage: "arrow.clockwise") { playback.retry() }
                        .buttonStyle(.bordered)
                }
                .padding(24).background(.black.opacity(0.8), in: .rect(cornerRadius: 20))
                .accessibilityIdentifier("memory-playback-error")
            }
            if showsControls {
                controls.transition(.opacity)
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["IMORA_MEMORY_DIAGNOSTICS"] == "1" {
                Text(verbatim: playback.diagnostic)
                    .font(.system(size: 1)).frame(width: 1, height: 1)
                    .accessibilityHidden(false)
                    .accessibilityIdentifier("memory-playback-probe")
                    .accessibilityValue(playback.diagnostic)
            }
            #endif
        }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .statusBarHidden(!showsControls)
        .task(id: session.client?.offlineAccountKey) {
            guard let client = session.client else { return }
            playback.start(client: client)
            scheduleControlHiding()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.pause(); setControls(true) }
        }
        .onChange(of: playback.isPlaying) { _, playing in
            if playing { scheduleControlHiding() } else { setControls(true) }
        }
        .onChange(of: playback.errorMessage) { _, error in
            if error != nil { setControls(true) }
        }
        .onChange(of: playback.isLoading) { _, loading in
            if loading { setControls(true) } else { scheduleControlHiding() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            playback.pause(); setControls(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            if notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                playback.pause(); setControls(true)
            }
        }
        .onChange(of: session.client?.offlineAccountKey) { _, _ in
            playback.stop(); dismiss()
        }
        .onDisappear { hideControlsTask?.cancel(); playback.stop() }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(memory.displayTitle).font(.headline).lineLimit(2)
                    Text("\(playback.index + 1) of \(playback.assets.count)")
                        .font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 16)
                Button { playback.stop(); dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .accessibilityLabel("Close").accessibilityIdentifier("memory-playback-close")
            }
            .padding(20)
            .background(LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom))
            Spacer(minLength: 0)
            VStack(spacing: 18) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 5) {
                            ForEach(Array(playback.assets.enumerated()), id: \.element.id) { index, asset in
                                Button { playback.select(index); setControls(true) } label: {
                                    MemoryAssetImage(asset: asset, pixels: 160)
                                        .frame(width: 40, height: 48)
                                        .clipShape(.rect(cornerRadius: 5))
                                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white, lineWidth: index == playback.index ? 2 : 0))
                                        .opacity(index == playback.index ? 1 : 0.6)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain).id(index)
                                .accessibilityLabel("Show item \(index + 1)")
                                .accessibilityIdentifier("memory-frame-\(index)")
                                .accessibilityAddTraits(index == playback.index ? .isSelected : [])
                            }
                        }.padding(.horizontal, 20)
                    }
                    .onChange(of: playback.index) { _, index in
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
                .frame(height: 48)
                ProgressView(value: playback.progress).tint(.white)
                    .animation(reduceMotion ? nil : .linear(duration: 0.1), value: playback.progress)
                    .accessibilityLabel("Slide progress")
                HStack(spacing: 32) {
                    Button { playback.select(playback.index - 1); setControls(true) } label: {
                        Image(systemName: "backward.end.fill").frame(width: 44, height: 44).contentShape(.rect)
                    }.disabled(playback.index == 0)
                        .accessibilityLabel("Previous").accessibilityIdentifier("memory-playback-previous")
                    Button { playback.togglePlayback(); setControls(true) } label: {
                        Image(systemName: playback.isFinished ? "arrow.counterclockwise" : playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title).frame(width: 56, height: 48)
                            .contentShape(.rect)
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    }
                    .accessibilityLabel(playback.isFinished ? "Replay" : playback.isPlaying ? "Pause" : "Play")
                    .accessibilityIdentifier("memory-playback-toggle")
                    Button { playback.select(playback.index + 1); setControls(true) } label: {
                        Image(systemName: "forward.end.fill").frame(width: 44, height: 44).contentShape(.rect)
                    }.disabled(playback.index + 1 == playback.assets.count)
                        .accessibilityLabel("Next").accessibilityIdentifier("memory-playback-next")
                    Spacer(minLength: 0)
                    Button { playback.toggleMuted(); setControls(true) } label: {
                        Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel(playback.isMuted ? "Unmute" : "Mute")
                    .accessibilityIdentifier("memory-playback-mute")
                }
                VStack(spacing: 3) {
                    Text(playback.musicUnavailable ? String(localized: "Music unavailable") : MemorySoundtrack.title)
                        .font(.caption.weight(.medium))
                    Text(verbatim: "\(MemorySoundtrack.artist) · CC0").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }.accessibilityIdentifier("memory-soundtrack")
            }
            .padding(20)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
        }
        .buttonStyle(.plain)
    }

    private func setControls(_ visible: Bool) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsControls = visible }
        scheduleControlHiding()
    }

    private func scheduleControlHiding() {
        hideControlsTask?.cancel()
        guard showsControls, playback.isPlaying, !playback.isLoading, playback.errorMessage == nil,
              !UIAccessibility.isVoiceOverRunning else { return }
        hideControlsTask = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsControls = false }
        }
    }
}
