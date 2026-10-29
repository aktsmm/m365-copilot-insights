"""Viva Copilot ダッシュボードの「データのエクスポート」を CDP で自動実行し、CSV を保存する。

前提: Edge を --remote-debugging-port=9222 で起動し、Insights Analyst 以上でサインイン済みの
analysis.insights.cloud.microsoft/CopilotDashboard タブを開いておく。資格情報は扱わない。
使い方: python viva_export_cdp.py <出力ディレクトリ> [待機秒(既定180)]
結果: ダウンロードされたファイル名を表示し、0件なら終了コード2（空データ／最小グループサイズ未満の可能性）。
"""
import json, os, sys, time, urllib.request
import websocket

out = os.path.abspath(sys.argv[1])
wait = int(sys.argv[2]) if len(sys.argv) > 2 else 180
os.makedirs(out, exist_ok=True)
tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json/list"))
tab = next((t for t in tabs if "analysis.insights.cloud.microsoft/CopilotDashboard" in t["url"]), None)
if not tab:
    sys.exit("Copilot ダッシュボードのタブが見つかりません")
ws = websocket.create_connection(tab["webSocketDebuggerUrl"], timeout=10)
n = [0]


def call(method, params=None):
    n[0] += 1
    ws.send(json.dumps({"id": n[0], "method": method, "params": params or {}}))
    while True:
        r = json.loads(ws.recv())
        if r.get("id") == n[0]:
            return r


call("Page.bringToFront")
call("Browser.setDownloadBehavior", {"behavior": "allow", "downloadPath": out, "eventsEnabled": True})
pos = call("Runtime.evaluate", {"returnByValue": True, "expression":
    "(()=>{const b=[...document.querySelectorAll('button')].find(e=>/エクスポート|Export/.test(e.getAttribute('aria-label')||e.title||e.innerText||''))||document.querySelector('button[aria-label*=xport]');"
    "if(!b)return null;const r=b.getBoundingClientRect();return JSON.stringify({x:r.x+r.width/2,y:r.y+r.height/2})})()"})["result"]["result"].get("value")
p = json.loads(pos) if pos else {"x": 1512, "y": 130}
for kind in ("mousePressed", "mouseReleased"):
    call("Input.dispatchMouseEvent", {"type": kind, "x": p["x"], "y": p["y"], "button": "left", "clickCount": 1})
ws.settimeout(5)
end = time.time() + wait
done = False
while time.time() < end and not done:
    try:
        ev = json.loads(ws.recv())
    except Exception:
        continue
    if ev.get("method", "").startswith("Browser.download"):
        print(ev["method"], ev["params"].get("suggestedFilename", ""), ev["params"].get("state", ""))
        done = ev["params"].get("state") == "completed"
files = os.listdir(out)
print(files)
sys.exit(0 if files else 2)
