# Speedtest

Teste de velocidade da internet que fica na barra de menus do macOS (sem ícone no Dock).

- Na barra de menus, o **tráfego ao vivo** do Mac (↓ download e ↑ upload, atualizado a cada
  segundo). Pela engrenagem dá para trocar por "velocidade do último teste" ou "só o ícone".

- Dois tipos de teste, escolhidos na engrenagem (o padrão é o da Apple):
  - **Apple**: o `networkQuality` da própria Apple, até a rede da Apple (São Paulo).
    Mostra o que você sente no uso real.
  - **Operadora** (estilo Speedtest): até um servidor da rede Speedtest (Ookla) perto de
    você, de preferência da sua operadora (no caso da Nio, os da V.tal). Usa a lista pública
    de servidores e os endpoints HTTPS deles, com 8 conexões em paralelo. Não é uma API
    oficial da Ookla, então pode mudar no futuro.
- Velocímetro em meia-lua (escala 0 · 5 · 10 · 50 · 100 · 250 · 500 · 750 · 1G) que enche
  ao vivo: azul no download, roxo no upload.
- Resultado: download, upload, latência e latência com carga (a latência enquanto a
  conexão está cheia, que mostra se a internet "trava" quando alguém baixa algo pesado),
  com o servidor em nome legível ("Apple · São Paulo", "Vtal · Curitiba").
- Cada teste registra se foi por **Wi-Fi** ou **cabo**. No Wi-Fi, guarda também faixa,
  canal, sinal (dBm), ruído e taxa do link, lidos no início do teste pelo CoreWLAN (sem
  pedir permissão de Localização; por isso o nome da rede não aparece).
- O histórico filtra por conexão, mostra a média da seleção e um gráfico do download
  com uma linha para Wi-Fi e outra para cabo.
- O teste pode ser cancelado no meio (botão Cancelar ou Esc).
- Teste automático (a cada 1, 3, 6 ou 12 horas) que se adia sozinho no hotspot do celular,
  no Modo de Poucos Dados e, se você quiser, na bateria. Ele só notifica quando algo foge
  do normal: falha, ou download abaixo da metade do típico para aquela conexão.
- Ajustes na engrenagem: servidor do teste, o que mostrar na barra de menus, teste
  automático, "automático só no carregador" e abrir ao iniciar a sessão.
- Segue o modo claro/escuro do sistema.

Usa só o que vem no macOS (SwiftUI, Charts, CoreWLAN, Network, SystemConfiguration, `networkQuality`).
Não há bibliotecas de terceiros. Cada teste consome em torno de 1 GB numa fibra de 500 Mb.

## Compilar e instalar

Só precisa das Command Line Tools (não precisa do Xcode):

```bash
scripts/build.sh --install
```

Isso gera `dist/Speedtest.app`, copia para `~/Applications` e abre. O ícone de
velocímetro aparece na barra de menus. Para sair, use a engrenagem no canto do painel.

## Ícone

O ícone (setas de download e upload) é desenhado em código em `Sources/Speedtest/GaugeIcon.swift`,
que gera tanto o ícone colorido do app quanto a versão de uma cor da barra de menus. Não usa
SF Symbols, porque a licença da Apple não permite símbolos em ícones de app. Os arquivos
gerados ficam em `Resources/AppIcon.iconset` e `Resources/AppIcon.icns`; para redesenhar:

```bash
scripts/make-icon.sh
```

Há seis estilos desenhados (Noturno; Claro; Azul do sistema; Clássico; Setas ↓↑, o atual;
Meia-lua sólida). Para comparar, `.build/debug/Speedtest --opcoes-icone /tmp/opcoes.png`; para
trocar, mude `GaugeIcon.style` e rode `scripts/make-icon.sh`.

## Dados

O histórico fica em `~/Library/Application Support/Speedtest/historico.json`.

## Para desenvolvimento

```bash
swift build
.build/debug/Speedtest --snapshot /tmp/snap   # salva PNGs do painel (claro e escuro), com histórico de exemplo
.build/debug/Speedtest --teste apple          # teste real no terminal, sem gravar no histórico
.build/debug/Speedtest --teste operadora      # idem, no estilo Speedtest
.build/debug/Speedtest --teste apple --cancelar-em 6   # testa o cancelamento
.build/debug/Speedtest --trafego                # imprime o tráfego ao vivo por 5 s
```

Observação: o SwiftUI deste macOS implementa `@State` como macro, que só compila com
o Xcode completo. Por isso o código usa `@StateObject` e `@AppStorage` no lugar.
