import SwiftUI

// PROTÓTIPO (só visual, dados fictícios): como ficaria a rede de Macs na rede local.
// Renderizado por `Fluxo --prototipo-rede <pasta>`; ainda não está ligado ao app.

struct PeerPreview: Identifiable {
    let id = UUID()
    let name: String
    let symbol: String
    let connection: ConnectionKind
    let wifiLine: String?
    let liveDown: Double
    let liveUp: Double
    let lastDown: Int
    let lastUp: Int
    let lastWhen: String
    var testing: Double? = nil
}

enum NetworkPrototype {
    static let peers: [PeerPreview] = [
        PeerPreview(name: "iMac do Escritório", symbol: "desktopcomputer", connection: .cabo, wifiLine: nil,
                    liveDown: 2_400_000, liveUp: 310_000, lastDown: 921, lastUp: 486, lastWhen: "há 2 h"),
        PeerPreview(name: "MacBook Air da Ana", symbol: "laptopcomputer", connection: .wifi,
                    wifiLine: "5 GHz · sinal bom", liveDown: 48_000_000, liveUp: 1_100_000,
                    lastDown: 312, lastUp: 188, lastWhen: "testando agora", testing: 284),
        PeerPreview(name: "Mac mini da Sala", symbol: "macmini", connection: .wifi,
                    wifiLine: "2,4 GHz · sinal fraco", liveDown: 85_000, liveUp: 40_000,
                    lastDown: 96, lastUp: 41, lastWhen: "ontem"),
    ]
}

/// A seção nova do painel.
struct OtherMacsPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Outros Macs")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {} label: { Label("Parear", systemImage: "plus") }
                    .controlSize(.small)
            }
            ForEach(Array(NetworkPrototype.peers.enumerated()), id: \.element.id) { i, peer in
                if i > 0 { Divider() }
                row(peer)
            }
            Divider()
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                Text("3 Macs · direto e criptografado")
                    .lineLimit(1)
                Spacer()
                Button("Testar todos") {}
                    .controlSize(.small)
                    .help("Um de cada vez, para um teste não atrapalhar o outro")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .module()
    }

    private func row(_ p: PeerPreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: p.symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(p.name).font(.callout.weight(.medium)).lineLimit(1)
                        Circle().fill(.green).frame(width: 6, height: 6).help("Ao vivo")
                    }
                    Label(p.wifiLine.map { "Wi-Fi · \($0)" } ?? "Cabo", systemImage: p.connection.symbol)
                        .font(.caption2)
                        .foregroundStyle(p.wifiLine?.contains("fraco") == true ? .orange : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("↓ " + TrafficBadge.format(p.liveDown))
                    Text("↑ " + TrafficBadge.format(p.liveUp))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            }
            HStack(spacing: 6) {
                if let speed = p.testing {
                    ProgressView(value: 0.35).frame(width: 60)
                    Text("↓ \(Int(speed)) Mbps")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.blue)
                    Spacer()
                    Button("Cancelar") {}.controlSize(.mini)
                } else {
                    Text("↓ \(p.lastDown)").foregroundStyle(.blue)
                    + Text("  ↑ \(p.lastUp)").foregroundStyle(.purple)
                    + Text("  · \(p.lastWhen)").foregroundStyle(.secondary)
                    Spacer()
                    Button {} label: { Label("Testar", systemImage: "play.fill") }
                        .controlSize(.mini)
                }
            }
            .font(.caption.monospacedDigit())
            .padding(.leading, 34)
        }
        .padding(.vertical, 2)
    }
}

/// Tela de pareamento: este Mac lista quem está na rede e pede o código mostrado no outro.
struct PairingPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Parear com outro Mac").font(.headline)
                Spacer()
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            Text("Macs com o Fluxo aberto nesta rede:")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                found("iMac do Escritório", "desktopcomputer", selected: true)
                Divider()
                found("MacBook Air da Ana", "laptopcomputer", selected: false, paired: true)
            }
            .module()

            VStack(alignment: .leading, spacing: 8) {
                Text("Digite o código que apareceu no iMac do Escritório:")
                    .font(.callout)
                HStack(spacing: 6) {
                    ForEach(Array("482   ".enumerated()), id: \.offset) { i, ch in
                        Text(String(ch).trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                            .frame(width: 36, height: 44)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(i == 3 ? Color.accentColor : .clear, lineWidth: 2))
                        if i == 2 { Text("–").foregroundStyle(.tertiary) }
                    }
                }
                Label("Os Macs só trocam dados depois do código. A conexão é criptografada e fica só na sua rede.",
                      systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancelar") {}
                Button("Parear") {}.buttonStyle(.borderedProminent).disabled(true)
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(width: 330)
    }

    private func found(_ name: String, _ symbol: String, selected: Bool, paired: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
            Text(name).font(.callout)
            Spacer()
            if paired {
                Label("Pareado", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if selected {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// O que aparece no outro Mac enquanto você digita o código.
struct PairingCodePreview: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "laptopcomputer.and.arrow.down").font(.system(size: 28)).foregroundStyle(.blue)
            Text("MacBook Pro do Marcos quer se conectar").font(.headline).multilineTextAlignment(.center)
            Text("Digite este código no outro Mac:").font(.callout).foregroundStyle(.secondary)
            Text("482 913")
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                .tracking(4)
            Button("Recusar") {}.controlSize(.large)
        }
        .padding(18)
        .frame(width: 300)
    }
}
