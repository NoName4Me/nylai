# 产品约束

<!-- impeccable:product-schema 1 -->

## Platform

原生 macOS 菜单栏应用。

## Stack

用户授权技术负责人选择：Swift 6、SwiftUI 与必要的 AppKit，优先系统 API。

## Users

初期供项目拥有者本人使用，后续面向普通 macOS 用户。

## Product Purpose

轻量整合常用生产力工具；从可运行基础工程开始，当前支持固定全局快捷键和主显示器 PNG 截图。

## Capabilities and Constraints

本地优先、菜单栏常驻、功能按目录隔离；无账号、云端或服务器。不默认启用 App Sandbox。已确认优先开发全局快捷键配置，随后分期完成截图选择、编辑、置顶透明度、最近截图、拼图和手动滚动拼接，详见 [需求规格](docs/REQUIREMENTS.md)。剪贴板与 Todo 需求尚未确定。

## Product Principles

原生交互、按需申请权限、减少后台开销、避免过度设计。页面只保留核心信息和必要操作。
