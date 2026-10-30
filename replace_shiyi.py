# -*- coding: utf-8 -*-
import io
p = r'E:\GGUF_Web\ios\GGUFApp\index.html'
c = io.open(p, encoding='utf-8').read()
reps = [
    ("<title>拾壹 · 本地 Agent</title>", "<title>GGUF · 本地 Agent</title>"),
    ('      <h1 id="whoTitle">拾壹</h1>', '      <h1 id="whoTitle">GGUF</h1>'),
    ('<div class="sub" id="whoSub">总管 · 推理在本机 · 只监听本机</div>', '<div class="sub" id="whoSub">GGUF · 推理在本机 · 零Token消耗</div>'),
    ("<b>拾壹在这儿</b>", "<b>GGUF 在这儿</b>"),
    ('ask.textContent = "问拾壹";', 'ask.textContent = "问 GGUF";'),
    ('whoTitle.textContent = isShier ? "拾贰" : "拾壹";', 'whoTitle.textContent = "GGUF";'),
    ('    : "总管 · 推理在本机 · 只监听本机";', '    : "GGUF · 推理在本机 · 零Token消耗";'),
    ('btnWho.title = isShier ? "切回拾壹" : "切到拾贰";', 'btnWho.title = "GGUF";'),
    ('toast("拾壹在线，可以说话");', 'toast("GGUF 在线，可以说话");'),
]
for old, new in reps:
    if old in c:
        c = c.replace(old, new)
        print("OK:", old[:40])
    else:
        print("MISS:", old[:40])
io.open(p, 'w', encoding='utf-8', newline='').write(c)
print("剩余拾壹/拾贰:", c.count("拾壹") + c.count("拾贰"))
