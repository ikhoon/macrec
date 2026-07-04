// C interop for the SpeexDSP acoustic echo canceller (speaker→mic echo reduction).
// Statically linked (libspeexdsp.a) so the .app stays self-contained. See install.sh / ci.yml.
#include <speex/speex_echo.h>
#include <speex/speex_preprocess.h>
