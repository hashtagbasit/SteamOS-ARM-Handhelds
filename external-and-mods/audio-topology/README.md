# Audio topologies

AudioReach topology sources for the DSP's audio graphs, and the blobs built
from them that the images install over the kernel package's copies.

| Device | Source | Installed as |
| --- | --- | --- |
| AYN Odin 3 | `sm8750/SM8750-AYN.m4` | `/usr/lib/firmware/qcom/sm8750/SM8750-AYN-tplg.bin` |

The Odin 3 graph is the stock one (speakers on SECONDARY MI2S SD0,
WCD939x headphones and headset mic) plus MultiMedia4 to DISPLAY_PORT_RX_0, so
sound goes out over USB-C to a monitor. Built without DP (`-DWITH_DP=0`) it
decompiles to the same graph as the stock blob; the only difference is the
module port counts (tokens 204/205) the current generator adds.

Rebuild (the build VM, any Ubuntu with alsa-utils and m4):

```sh
git clone https://git.codelinaro.org/linaro/qcomlt/audioreach-topology.git
m4 -I audioreach-topology sm8750/SM8750-AYN.m4 > SM8750-AYN.conf
alsatplg -c SM8750-AYN.conf -o sm8750/SM8750-AYN-tplg.bin
```

The "undefined widget/stream" warnings are expected: the back ends come from
the kernel's DAI links.
