{
  pkgs,
  lib ? pkgs.lib,
  ...
}:

let
  rawSrc = pkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.3.tar.xz";
    sha256 = "sha256-vkHAaOiPUkKhm8zb/74HexjEe0X2J+IyVQS0+red0dw=";
  };

  patchedSrc = pkgs.applyPatches {
    src = rawSrc;
    patches = [
      ./patches/0001-clang-polly.patch
      ./patches/0001-acpi-call.patch
    ];
    patchFlags = [ "-p1" ];

    postPatch = ''
      # BMQ/PRJC scheduler patch: two hunks (idle.c #1/#2, init/Kconfig #6)
      # touch CONFIG_SCHED_POC_SELECTOR, a feature that doesn't exist in
      # vanilla v7.1.3 at all — confirmed via clean-tree testing. Their
      # rejection is expected and harmless; every hunk that matters
      # (the actual CONFIG_SCHED_ALT guards, alt_core.c, etc.) applies
      # cleanly. Tolerate the known rejects rather than hard-failing.
      patch -p1 -f < ${./patches/0001-prjc-cachy-lfbmq-fixed.patch} || true
      rm -f init/Kconfig.rej kernel/sched/idle.c.rej

      # ISA/uarch patch: most hunks apply cleanly (adds MIVYBRIDGE, MZEN2-5,
      # MALDERLAKE etc.), but two dependency-list hunks (X86_L1_CACHE_SHIFT,
      # X86_CMOV/X86_MINIMUM_CPU_FAMILY) reject — v7.1.3 upstream already
      # dropped legacy 486-era Kconfig entries the patch's context expects,
      # so the context itself has genuinely changed, not just shifted.
      # Apply what applies, tolerate the two known rejects, then hand-fix
      # those two blocks directly (verified working in dev-shell testing).
      patch -p1 --fuzz=0 -f < ${./patches/more-ISA-levels-and-uarches-for-kernel-6.16+.patch} || true

      # DEBUG: print exactly what failed to match before we destroy the
      # evidence. This is the actual context patch expected vs what's
      # really in the v7.1.3 tree — read this in the CI log first.
      if [ -f arch/x86/Kconfig.cpu.rej ]; then
        echo "=== arch/x86/Kconfig.cpu.rej ==="
        cat arch/x86/Kconfig.cpu.rej
        echo "=== end .rej ==="
      fi
      rm -f arch/x86/Kconfig.cpu.rej arch/x86/Makefile.rej

      # Hand-fix the two dependency-list hunks that always reject (verified
      # against a clean v7.1.3 tree). Plain sed/grep only — python3 isn't
      # available in the minimal stdenvNoCC sandbox this phase runs under.
      sed -i 's@^\tdefault "7" if MPENTIUM4$@\tdefault "7" if MPENTIUM4 || MPSC@' arch/x86/Kconfig.cpu
      sed -i 's@^\tdefault "6" if MK7 || MPENTIUMM || MATOM || MVIAC7 || X86_GENERIC || X86_64$@\tdefault "6" if MK7 || MK8 || MPENTIUMM || MCORE2 || MATOM || MVIAC7 || X86_GENERIC || GENERIC_CPU || MK8SSE3 || MK10 || MBARCELONA || MBOBCAT || MJAGUAR || MBULLDOZER || MPILEDRIVER || MSTEAMROLLER || MEXCAVATOR || MZEN || MZEN2 || MZEN3 || MZEN4 || MZEN5 || MNEHALEM || MWESTMERE || MSILVERMONT || MGOLDMONT || MGOLDMONTPLUS || MSANDYBRIDGE || MIVYBRIDGE || MHASWELL || MBROADWELL || MSKYLAKE || MSKYLAKEX || MCANNONLAKE || MICELAKE_CLIENT || MICELAKE_SERVER || MCASCADELAKE || MCOOPERLAKE || MTIGERLAKE || MSAPPHIRERAPIDS || MROCKETLAKE || MALDERLAKE || MRAPTORLAKE || MMETEORLAKE || MEMERALDRAPIDS || MDIAMONDRAPIDS || X86_NATIVE_CPU@' arch/x86/Kconfig.cpu
      sed -i 's@^\tdepends on (MK7 || MPENTIUM4 || MPENTIUMM || MPENTIUMIII || MPENTIUMII || M686 || MVIAC3_2 || MVIAC7 || MCRUSOE || MEFFICEON || MATOM || MGEODE_LX || X86_64)$@\tdepends on (MK8 || MK7 || MCORE2 || MPENTIUM4 || MPENTIUMM || MPENTIUMIII || MPENTIUMII || M686 || MVIAC3_2 || MVIAC7 || MCRUSOE || MEFFICEON || X86_64 || MATOM || MGEODE_LX)@' arch/x86/Kconfig.cpu
      sed -i 's@^\tdefault "6" if X86_32 && (MPENTIUM4 || MPENTIUMM || MPENTIUMIII || MPENTIUMII || M686 || MVIAC3_2 || MVIAC7 || MEFFICEON || MATOM || MK7)$@\tdefault "6" if X86_32 && (MPENTIUM4 || MPENTIUMM || MPENTIUMIII || MPENTIUMII || M686 || MVIAC3_2 || MVIAC7 || MEFFICEON || MATOM || MCORE2 || MK7 || MK8)@' arch/x86/Kconfig.cpu

      # DEBUG: dump the real post-sed content around the target blocks,
      # regardless of whether the grep checks below pass. This is the
      # ground truth for what the Kconfig parser will actually see.
      echo "=== Kconfig.cpu around X86_L1_CACHE_SHIFT / X86_CMOV / X86_MINIMUM_CPU_FAMILY ==="
      grep -n -A3 -B1 '^config X86_L1_CACHE_SHIFT$\|^config X86_CMOV$\|^config X86_MINIMUM_CPU_FAMILY$' arch/x86/Kconfig.cpu
      echo "=== end dump ==="

      # Fail loudly (not silently) if any of the three fixes didn't land —
      # e.g. if upstream drifts again in a future kernel bump.
      # NOTE: the old MPSC check was a false positive — 'MPSC' is also the
      # name of a brand-new config symbol the ISA patch adds elsewhere in
      # this same file, so the grep passed even when this specific sed did
      # nothing. Anchored on the full resulting line instead.
      grep -q 'default "7" if MPENTIUM4 || MPSC$' arch/x86/Kconfig.cpu || { echo "ERROR: X86_L1_CACHE_SHIFT (line1) hand-fix did not apply"; exit 1; }
      grep -q 'default "6" if MK7 || MK8 || MPENTIUMM || MCORE2' arch/x86/Kconfig.cpu || { echo "ERROR: X86_L1_CACHE_SHIFT (line2) hand-fix did not apply"; exit 1; }
      grep -q 'depends on (MK8 || MK7 || MCORE2 || MPENTIUM4' arch/x86/Kconfig.cpu || { echo "ERROR: X86_CMOV hand-fix did not apply"; exit 1; }
      grep -q 'default "6" if X86_32 && (MPENTIUM4 || MPENTIUMM || MPENTIUMIII || MPENTIUMII || M686 || MVIAC3_2 || MVIAC7 || MEFFICEON || MATOM || MCORE2 || MK7 || MK8)$' arch/x86/Kconfig.cpu || { echo "ERROR: X86_MINIMUM_CPU_FAMILY hand-fix did not apply"; exit 1; }
    '';
  };
in
lib.makeOverridable pkgs.linuxManualConfig {
  stdenv = pkgs.llvmPackages.stdenv;
  src = patchedSrc;

  version = "7.1.3-lfbmq";
  modDirVersion = "7.1.3";
  pname = "linux-lfbmq";
  configfile = ./lfbmq.config;
  allowImportFromDerivation = true;
  extraMakeFlags = [ "LLVM=1" ];

  features = {
    efiBootStub = true;
    ia32Emulation = true;
  };
}
