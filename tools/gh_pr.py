#!/usr/bin/env python3
"""通过 GitHub API 完成「提交 / 建 PR / 合并」，不依赖 gh CLI。

凭据从 `git credential fill` 取 —— 也就是 GitHub Desktop 登录后存在
Windows 凭据管理器里的那一份，**不读环境变量、不写任何文件、不打印 token**。

为什么要有这个脚本：
  这台机器的 git push 有时会被网络策略掐断（clone 时遇到过 502），
  但 api.github.com 是通的。所以准备两条路径：
    · 日常：`git push` 推分支 → 本脚本建 PR + 合并；
    · git 完全不通时：用 `put` 子命令走 Contents API 直接改单个文件。

用法：
    python tools/gh_pr.py pr  --title "feat: xxx" [--body-file docs/pr.md] [--merge]
    python tools/gh_pr.py pr  --title "fix: xxx" --branch hotfix/a --merge
    python tools/gh_pr.py put --path docs/x.md --message "docs: 更新" [--branch main]
    python tools/gh_pr.py status
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

OWNER = "118coder"
REPO = "qianyi-monv"
API = f"https://api.github.com/repos/{OWNER}/{REPO}"


def get_token() -> str:
    """从 git credential manager 取 token（GitHub Desktop 登录过即可）。"""
    p = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True, text=True, timeout=20,
    )
    for line in p.stdout.splitlines():
        if line.startswith("password="):
            return line[len("password="):]
    return ""


class Api:
    def __init__(self, token: str):
        self.h = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "qy-creator-tools",
        }

    def call(self, method, path, payload=None):
        data = json.dumps(payload).encode() if payload is not None else None
        url = path if path.startswith("http") else f"{API}{path}"
        req = urllib.request.Request(url, data=data, headers=self.h, method=method)
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return r.status, json.loads(r.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            body = e.read().decode() or "{}"
            try:
                return e.code, json.loads(body)
            except json.JSONDecodeError:
                return e.code, {"message": body}


def git(*args, check=True):
    r = subprocess.run(["git", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.exit(f"git {' '.join(args)} 失败：{r.stderr.strip()}")
    return r.stdout.strip()


def current_branch() -> str:
    return git("rev-parse", "--abbrev-ref", "HEAD")


def cmd_status(api: Api):
    st, me = api.call("GET", "https://api.github.com/user")
    print(f"凭据身份：{me.get('login', '?')}" if st == 200 else f"凭据校验失败 {st}")
    print(f"当前分支：{current_branch()}")
    st2, prs = api.call("GET", "/pulls?state=open")
    if st2 == 200:
        print(f"开放中的 PR：{len(prs)} 个")
        for p in prs:
            print(f"  #{p['number']} {p['title']}  ({p['head']['ref']} → {p['base']['ref']})")


def cmd_pr(api: Api, args):
    branch = args.branch or current_branch()
    base = args.base
    if branch == base:
        sys.exit(f"当前就在 {base} 上，PR 需要一个独立分支（--branch 指定）")

    # 1) 推分支（git 通道通时用它；不通就报错并提示走 put 子命令）
    print(f"[1/3] 推送 {branch} …")
    r = subprocess.run(["git", "push", "-u", "origin", branch],
                       capture_output=True, text=True,
                       env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
    if r.returncode != 0:
        sys.exit("推送失败。若网络原因，改用 put 子命令走 Contents API，或先在 GitHub Desktop 里推送。\n"
                 + r.stderr.strip()[-400:])
    print("      已推送")

    # 2) 建 PR
    print("[2/3] 创建 PR …")
    body = ""
    if args.body_file and os.path.exists(args.body_file):
        body = open(args.body_file, encoding="utf-8").read()
    elif args.body:
        body = args.body

    st, pr = api.call("POST", "/pulls", {
        "title": args.title, "head": branch, "base": base, "body": body,
    })
    if st == 422 and "already exists" in str(pr.get("errors", "")):
        st2, prs = api.call("GET", f"/pulls?state=open&head={OWNER}:{branch}")
        if st2 != 200 or not prs:
            sys.exit("已存在 PR 但查不到，请手动查看")
        pr = prs[0]
        print(f"      PR 已存在，复用 #{pr['number']}")
    elif st not in (200, 201):
        sys.exit(f"建 PR 失败 {st}: {pr.get('message')} {pr.get('errors', '')}")

    num, url = pr["number"], pr["html_url"]
    print(f"      PR #{num}  {url}")

    # 3) 可选合并
    if args.merge:
        print("[3/3] 合并 …")
        st3, res = api.call("PUT", f"/pulls/{num}/merge", {
            "merge_method": args.method,
            "commit_title": f"Merge pull request #{num}: {args.title}"[:250],
        })
        if st3 != 200:
            sys.exit(f"合并失败 {st3}: {res.get('message')}")
        print(f"      已合并，提交 {res.get('sha', '')[:10]}")
        print("\n提示：本地 main 需要 `git checkout main && git pull` 同步合并结果。")
    else:
        print("\n未合并（加 --merge 自动合并）。")

    print(f"\nPR: {url}")


def cmd_put(api: Api, args):
    """走 Contents API 直接提交单个文件 —— git 通道不通时的兜底路径。"""
    path = args.path.replace("\\", "/")
    if not os.path.exists(path):
        sys.exit(f"文件不存在：{path}")
    branch = args.branch or "main"

    st, cur = api.call("GET", f"/contents/{path}?ref={branch}")
    sha = cur.get("sha") if st == 200 else None

    content = base64.b64encode(open(path, "rb").read()).decode()
    payload = {"message": args.message, "content": content, "branch": branch}
    if sha:
        payload["sha"] = sha

    st2, res = api.call("PUT", f"/contents/{path}", payload)
    if st2 not in (200, 201):
        sys.exit(f"上传失败 {st2}: {res.get('message')}")
    print(f"已{'更新' if sha else '新建'} {path} @ {branch}")
    print(f"  提交 {res['commit']['sha'][:10]}  {res['commit']['html_url']}")


def main():
    ap = argparse.ArgumentParser(description="GitHub API 提交工具（复用 GitHub Desktop 凭据）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_pr = sub.add_parser("pr", help="推送分支 → 建 PR → 可选合并")
    p_pr.add_argument("--title", required=True)
    p_pr.add_argument("--body", default="")
    p_pr.add_argument("--body-file", default="")
    p_pr.add_argument("--branch", default="")
    p_pr.add_argument("--base", default="main")
    p_pr.add_argument("--merge", action="store_true")
    p_pr.add_argument("--method", default="merge", choices=["merge", "squash", "rebase"])

    p_put = sub.add_parser("put", help="用 Contents API 直接提交单个文件（git 不通时用）")
    p_put.add_argument("--path", required=True)
    p_put.add_argument("--message", required=True)
    p_put.add_argument("--branch", default="main")

    sub.add_parser("status", help="查看凭据身份与开放中的 PR")

    args = ap.parse_args()
    tok = get_token()
    if not tok:
        sys.exit("取不到 GitHub 凭据。请确认 GitHub Desktop 已登录，或 `git config credential.helper manager`。")
    api = Api(tok)

    if args.cmd == "status":
        cmd_status(api)
    elif args.cmd == "pr":
        cmd_pr(api, args)
    else:
        cmd_put(api, args)


if __name__ == "__main__":
    main()
