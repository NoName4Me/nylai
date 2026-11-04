# 产品约束

<!-- impeccable:product-schema 1 -->

## Platform

原生 macOS 菜单栏应用，适配浅色与深色外观。

## Stack

用户授权技术负责人选择：Swift 6、SwiftUI 与必要的 AppKit，优先系统 API。

## Users

初期供项目拥有者本人使用，后续面向普通 macOS 用户。

## Product Purpose

轻量整合常用生产力工具；现有全局快捷键配置、截图编辑、置顶、历史、拼图、手动滚动拼接、鼠标手势与剪贴板已代码完成，部分真实系统场景待人工验收。

## Capabilities and Constraints

本地优先、菜单栏常驻、功能按目录隔离；无账号、云端或服务器。不默认启用 App Sandbox。应用分组窗口切换首版已接入：同一面板内切应用与应用内窗口，覆盖当前桌面普通窗口和最小化窗口并使用内存预览缓存；视觉支持跟随系统、日间与夜间。应用名在简体中文系统显示“拈来”，其他语言显示“Nylai”。详见 [需求规格](docs/REQUIREMENTS.md) 与 [开发计划](docs/DEVELOPMENT_PLAN.md)。Todo 需求尚未确定。

## Product Principles

原生交互、按需申请权限、减少后台开销、避免过度设计。页面只保留核心信息和必要操作。
