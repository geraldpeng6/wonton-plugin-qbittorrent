# 云吞插件：qBittorrent

开发流程见[插件开发指南](https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md)。

云吞（Wonton）的 qBittorrent 插件：在共享文件夹 `downloads` 中下载和管理 BT 任务。网页经云吞网关访问，BT 连接端口按需开放到局域网。

这个插件使用上游官方镜像 `qbittorrentofficial/qbittorrent-nox`，默认简体中文界面、默认下载路径和临时路径都在 `downloads` 共享文件夹；网关来源地址写入 qBittorrent 的免认证白名单，因此打开网页不用再输一次密码。

## 图标来源与许可

`icon.svg` 使用 qBittorrent 官方标志；来源、处理方式、许可证全文和商标说明见 [NOTICE](NOTICE)。

## 先跑起来

```bash
scripts/dev.sh up
scripts/dev.sh install
```

`up` 在本机起一套云吞，打印它的地址。浏览器打开，用 `scripts/dev.sh token` 输出的用户令牌登录。`install` 先列出插件要的权限，确认后装上，打印 qBittorrent 网页的地址。打开就是中文 WebUI，不需要再输入 qBittorrent 密码。

下载默认写入共享文件夹 `downloads`；BT 端口 51413 的 TCP 和 UDP 可按安装时授权开放到局域网。应用网页只经云吞网关访问。

Chrome、Firefox 和 curl 把 `*.localhost` 直接解析到本机，不用改 hosts。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件本身：Compose 加上 `x-wonton` 清单 |
| `icon.svg`、`config/` | 清单和 Compose 引用的文件：官方图标、qBittorrent 配置种子和初始化脚本 |
| `screenshots/` | 商店详情页里的截图 |
| `scripts/check.sh` | 检查插件包，规则和安装时一样 |
| `scripts/dev.sh` | 开发环境：起一套云吞，装、重装、卸载插件，看日志 |
| `scripts/smoke-probes.sh` | `scripts/dev.sh smoke` 对这个插件逐项的探测 |
| `scripts/publish.sh` | 发布一个版本：打 tag、推送 |
| `AGENTS.md` | 给人和 AI 编程代理的规则 |
| `LICENSE`、`NOTICE` | 插件包许可证、上游许可证和商标声明 |
| `.wonton/` | 开发环境的设置、密钥和数据，不提交 |
