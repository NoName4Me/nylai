# nylai 品牌图标

图形沿用用户认可的禅意设计板，核心造型为带飞白笔触的双弧及朱砂色中央印记。这一版本根据设计板中的图像区域提取笔触像素轮廓，并重新导出图标，不再使用原来手工猜测的几何弧线。

- `nylai/Assets.xcassets/AppIcon.appiconset/`：macOS 全尺寸图标，16–1024 px。
- `nylai/Assets.xcassets/MenuBarIcon.imageset/`：单色模板图 18/36/54 px；由运行时 `isTemplate = true` 自动适配明暗系统菜单栏。
- `docs/brand/nylai-app-icon.svg`、`docs/brand/nylai-menubar.svg`：参考图像轮廓描摹版 SVG，包含飞白细节；PNG 是实际构建使用的资源。

原设计板为位图，SVG 是栅格轮廓描摹而非原生手绘矢量文件。内部功能图标不在本次变更中。
