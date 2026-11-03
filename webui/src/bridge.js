/* bridge.js — host(WebView2) ↔ UI 的唯一通道
 *
 * 关键约定：**UI 发出去的必须是 JSON 字符串**，不是对象。
 * 原因：宿主用的是 ICoreWebView2WebMessageReceivedEventArgs::TryGetWebMessageAsString，
 * 只收字符串消息；发对象会走 get_WebMessageAsJson 分支，宿主拿不到。
 *
 * 浏览器里直接打开 index.html 时没有 chrome.webview，这里会自动进入 mock 模式：
 * 用定时器造快照，方便美术/前端不启动游戏也能调样式。
 */
(function (global) {
  'use strict';

  var core = (global.chrome && global.chrome.webview) ? global.chrome.webview : null;
  var listeners = [];
  var mockTimer = null;

  function dispatch(raw) {
    var msg;
    try {
      msg = typeof raw === 'string' ? JSON.parse(raw) : raw;
    } catch (e) {
      console.warn('[bridge] 非法 JSON', e);
      return;
    }
    for (var i = 0; i < listeners.length; i++) {
      try { listeners[i](msg); } catch (err) { console.error('[bridge] handler error', err); }
    }
  }

  function post(obj) {
    var text = JSON.stringify(obj);
    if (core) {
      // WebView2：必须传字符串（见文件头）
      core.postMessage(text);
    } else {
      // 浏览器 / 单元调试
      console.log('[mock→host]', text);
      if (global.__qyMockEcho) global.__qyMockEcho(obj);
    }
  }

  function onMessage(fn) {
    if (typeof fn === 'function') listeners.push(fn);
  }

  function startMock() {
    if (core || mockTimer) return;
    var hp = 100, gold = 0, t = 0;
    mockTimer = setInterval(function () {
      t += 0.1;
      gold += Math.random() < 0.15 ? 1 : 0;
      dispatch({
        t: 'snapshot', seq: Math.round(t * 10),
        hp: hp, maxHp: 120, sp: 40 + Math.round(Math.sin(t) * 8), gold: gold, floor: 3,
        party: [
          { name: '剑士·凛', hp: 100, max: 120, cmd: 'follow' },
          { name: '弓手·凯', hp: 74, max: 92, cmd: 'attack' }
        ]
      });
    }, 100);
  }

  if (core) {
    core.addEventListener('message', function (e) { dispatch(e.data); });
  } else {
    global.addEventListener('message', function (e) { dispatch(e.data); });
    startMock();
  }

  global.QyBridge = {
    isNative: !!core,
    post: post,
    onMessage: onMessage,
    ready: function () { post({ t: 'ready' }); },
    close: function () { post({ t: 'close' }); },
    command: function (id, args) { post({ t: 'cmd', id: id, args: args || {} }); }
  };
})(window);
