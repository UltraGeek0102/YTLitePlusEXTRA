# YTLiquidGlass

A small Theos tweak that applies Apple's public `UIGlassEffect` to YouTube's existing pivot tab bar.

## Compatibility goal

This tweak intentionally **does not replace or rebuild the tab bar model/controller**. It styles the existing `YTPivotBarView` and `YTPivotBarItemView` instances at runtime. That means YTLite remains responsible for:

- which tabs are active
- tab order
- removing Home/Shorts/etc.
- adding History, Playlists, or other custom tabs
- current selected tab
- tab actions and long-press behavior

When YTLite refreshes/reorders the pivot bar, the glass styling follows the resulting views.

## Build

Requires an iOS 26+ SDK (your Xcode 27 / iOS 27 workflow is suitable) and Theos.

```sh
make clean package DEBUG=0 FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless ARCHS=arm64
```

The generated `.deb` can be passed to Cyan together with the other tweak packages.

## Workflow integration

Add a boolean workflow input such as `liquidglass`, create or checkout this folder in the runner workspace, then build it with:

```yaml
- name: Build YTLiquidGlass
  if: ${{ inputs.liquidglass }}
  run: |
    cd YTLiquidGlass
    make clean package DEBUG=0 FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless ARCHS=arm64
    mv packages/*.deb ${{ github.workspace }}/ytliquidglass.deb
```

Your existing `for f in *.deb` Cyan loop will inject it automatically.
