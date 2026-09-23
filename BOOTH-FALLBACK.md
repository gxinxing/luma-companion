# 现场降级方案

眼镜链路按以下顺序降级，任何样本都不得冒充实时设备采集。

## A：公网中台

设备页使用 `https://ytd.rickyke.com` 和现场操作员令牌。先运行一次：

```bash
TOKEN=<操作员令牌> ./verify-swarm.sh https://ytd.rickyke.com
```

脚本发送一条合成 `device/glasses` 刺激，只证明 HTTP 合同；真实演示仍应由眼镜新拍照片上传。

## B：本机 aria-swarm

手机与 Mac 连接同一局域网。服务必须监听所有地址，并把手机访问的 Host 加入允许列表：

```bash
cd /Users/ricky/Downloads/产品-咏叹调
ARIA_OPERATOR_TOKEN=test \
ARIA_BIND=0.0.0.0 \
ARIA_PUBLIC_HOSTS=<Mac局域网IP>:4179 \
PORT=4179 npm start
```

随后带 Bearer `test` 调用 `POST /api/run/start`。App 设备页填写 `http://<Mac局域网IP>:4179` 和令牌 `test`。这是同一套 aria-swarm 的本地实例，不得表述成公网演出。

## C：没有眼镜

可以用一次性调试注入验证 App 到中台的网络接缝，但调试代码必须在最终构建前恢复，并核对产物不含注入标记。合成图片产生的记录只能标作接缝验证证据，不能宣称眼镜 BLE 端到端已验。

本地相册不提供正式上传入口：相册图片来源不能证明是眼镜采集，上传会污染 `device/glasses` 账本。

## D：眼镜完全不可用

保留 App 和眼镜实物展示，蜂群改由观众触屏或挥手驱动。如实说明眼镜 BLE、拍照、实时和热点链路未在本场完成验证。
