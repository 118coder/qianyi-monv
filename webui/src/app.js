/* app.js — 把快照渲染进 DOM；所有交互只发命令，不改本地状态 */
(function (global) {
  'use strict';

  var $ = function (id) { return document.getElementById(id); };
  var els = {
    floor: $('floor'), gold: $('gold'), mode: $('mode'),
    hpFill: $('hp-fill'), hpText: $('hp-text'),
    spFill: $('sp-fill'), spText: $('sp-text'),
    party: $('party'), shop: $('shop'), toast: $('toast')
  };

  var toastTimer = null;

  function setBar(fill, text, value, max) {
    var pct = max > 0 ? Math.max(0, Math.min(1, value / max)) : 0;
    fill.style.width = (pct * 100).toFixed(1) + '%';
    if (text) text.textContent = value + ' / ' + max;
  }

  function renderParty(list) {
    if (!els.party) return;
    els.party.innerHTML = '';
    (list || []).forEach(function (m) {
      var li = document.createElement('li');
      var name = document.createElement('span');
      name.textContent = m.name;
      var hp = document.createElement('b');
      hp.textContent = m.hp + '/' + m.max;
      li.appendChild(name);
      li.appendChild(hp);
      els.party.appendChild(li);
    });
  }

  function showToast(text) {
    if (!text || !els.toast) return;
    els.toast.textContent = text;
    els.toast.classList.remove('hidden');
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { els.toast.classList.add('hidden'); }, 1600);
  }

  global.QyBridge.onMessage(function (msg) {
    switch (msg.t) {
      case 'snapshot':
        els.floor.textContent = '地下 ' + msg.floor + ' 层';
        els.gold.textContent = msg.gold + ' G';
        setBar(els.hpFill, els.hpText, msg.hp, msg.maxHp);
        setBar(els.spFill, els.spText, msg.sp, msg.sp + 10);
        renderParty(msg.party);
        if (msg.toast) showToast(msg.toast);
        break;
      case 'open':
        if (msg.screen === 'shop') els.shop.classList.remove('hidden');
        break;
      case 'close':
        if (msg.screen === 'shop') els.shop.classList.add('hidden');
        break;
    }
  });

  document.addEventListener('click', function (e) {
    var buy = e.target && e.target.getAttribute && e.target.getAttribute('data-buy');
    if (buy) {
      global.QyBridge.command('buy', { item: buy });
      return;
    }
    if (e.target && e.target.id === 'shop-close') {
      els.shop.classList.add('hidden');
      global.QyBridge.command('close', {});
    }
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') {
      els.shop.classList.add('hidden');
      global.QyBridge.close();
    }
  });

  els.mode.textContent = global.QyBridge.isNative ? 'WebView2' : '浏览器预览（mock）';
  global.QyBridge.ready();
})(window);
