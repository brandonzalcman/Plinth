import Foundation
import WebKit

/// The script that finds login forms. It runs in its own content world ("PlinthPasswords"): the page's scripts
/// cannot see its variables, call its fill function or read the messages it posts.
///
/// It reports four things to native code and never decides anything itself:
///  - `focus`: the person clicked or tabbed into a login field (only after a real pointer or key event, so a page
///    cannot trigger a fill by calling `focus()`); `focusIdentifier` is the same for a user name field on a
///    sign-in step that has no password field yet;
///  - `submit`: a login form was submitted, with what was typed; `identifier`: the first step of a two-step sign-in;
///  - `loaded` / `settled`: a document has settled, or (single-page apps) the form went away after a submit,
///    which is how native code tells a successful login from a failed one.
///
/// It finds fields at the moment of each event rather than at load, so forms that appear late, formless logins
/// and fields inside open shadow roots all work.
/// The only way back in is `fill`, called by native code with the secret as an argument.
public enum PasswordPageScript {
    public static let handlerName = "plinthPasswords"
    public static let world = WKContentWorld.world(name: "PlinthPasswords")

    public static func userScript() -> WKUserScript {
        // Every frame: native code matches a frame's logins against that frame's own origin, never the page around it.
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world)
    }

    /// Scripted test launches only (`PLINTH_STEPS` set with a throwaway `PLINTH_STORAGE` profile): lets scripted events stand in for real input.
    public static func testModeScript() -> WKUserScript {
        WKUserScript(source: "window.__plinthPwTest = true;", injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }

    /// The JavaScript that fills field values; run through `callAsyncJavaScript` with these argument names.
    public static let fillBody = "return window.__plinthPwFill(token, username, password);"

    static let source = #"""
    (function () {
      if (window.__plinthPw) { return; }
      window.__plinthPw = true;
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\#(handlerName);
      if (!handler) { return; }
      var entries = {};
      var nextToken = 1;
      var lastGesture = 0;
      var lastSubmit = { key: '', at: 0 };
      var lastConsidered = { el: null, at: 0 };
      var knownPw = new WeakSet();   // fields that were password fields, even if a "show" button turned them into text
      var settling = false;

      // Real input only. (`window.__plinthPwTest` lives in this script's own world, which page scripts cannot reach;
      // test launches set it so scripted events count.)
      function trusted(ev) { return ev.isTrusted || window.__plinthPwTest === true; }

      function visible(el) {
        if (!el || !el.isConnected) { return false; }
        var r = el.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) { return false; }
        var s = getComputedStyle(el);
        return s.visibility !== 'hidden' && s.display !== 'none';
      }
      // Every input under `root`, in document order, including inside open shadow roots.
      function inputsIn(root) {
        var out = [];
        (function walk(node) {
          for (var c = node.firstElementChild; c; c = c.nextElementSibling) {
            if (c.tagName === 'INPUT') { out.push(c); }
            if (c.shadowRoot) { walk(c.shadowRoot); }
            walk(c);
          }
        })(root);
        return out;
      }
      function targetOf(ev) {
        var path = ev.composedPath ? ev.composedPath() : null;
        return path && path.length ? path[0] : ev.target;
      }
      function isPw(el) { return el && el.tagName === 'INPUT' && (el.type === 'password' || knownPw.has(el)); }
      function scope(el) { return el.form || document; }
      function passwordFields(root) { return inputsIn(root).filter(function (e) { return isPw(e) && visible(e); }); }
      function hint(el) { return (el.getAttribute('autocomplete') || '').toLowerCase(); }
      function isNewAttr(el) { return hint(el).indexOf('new-password') >= 0; }
      function isCurrentAttr(el) { return hint(el).indexOf('current-password') >= 0; }
      // Sign-up and change-password forms: a "new-password" hint, or several password fields and no "current-password" hint.
      function isNewForm(pw) {
        if (isNewAttr(pw)) { return true; }
        var all = passwordFields(scope(pw));
        return all.length > 1 && !all.some(isCurrentAttr);
      }
      function textLike(el) {
        if (isPw(el)) { return false; }
        var t = (el.getAttribute('type') || 'text').toLowerCase();
        return t === 'text' || t === 'email' || t === 'tel' || t === 'url';
      }
      function usernameFor(pw) {
        var inputs = inputsIn(scope(pw));
        var i = inputs.indexOf(pw);
        for (var j = i - 1; j >= 0; j--) {
          if (textLike(inputs[j]) && visible(inputs[j])) { return inputs[j]; }
        }
        // Some sign-in pages keep the user name in a hidden field once the second step shows.
        for (var k = 0; k < inputs.length; k++) {
          if (textLike(inputs[k]) && inputs[k].value !== '' && hint(inputs[k]).indexOf('username') >= 0) { return inputs[k]; }
        }
        return null;
      }
      // A field that asks who is signing in, on a step that has no password field yet.
      function identifierLike(el) {
        if (!textLike(el)) { return false; }
        if (/username|email|webauthn/.test(hint(el)) || (el.getAttribute('type') || '').toLowerCase() === 'email') { return true; }
        var s = [el.name, el.id, el.placeholder, el.getAttribute('aria-label')].join(' ').toLowerCase();
        return /user|e-?mail|login|identifier|account|phone/.test(s) && !/search|subscribe|newsletter|coupon/.test(s);
      }
      function register(pw, user) {
        for (var k in entries) { if (entries[k].pw === pw && entries[k].user === user) { return Number(k); } }
        var token = nextToken++;
        entries[token] = { pw: pw, user: user };
        return token;
      }
      function actionOf(el) {
        var f = el.form;
        var a = f && f.getAttribute('action');
        if (!a) { return ''; }
        try { return new URL(a, document.baseURI).href; } catch (e) { return a; }
      }
      function send(body) { try { handler.postMessage(body); } catch (e) {} }

      function setValue(el, value) {
        if (!el || !el.isConnected) { return; }
        var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        setter.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
      // Called by native code only, with the login the person chose. An empty password fills the user name alone.
      window.__plinthPwFill = function (token, username, password) {
        var e = entries[token];
        if (!e) { return false; }
        var done = false;
        if (e.user && e.user.isConnected && username !== '') { setValue(e.user, username); done = true; }
        if (e.pw && e.pw.isConnected && password !== '') { setValue(e.pw, password); done = true; }
        return done;
      };

      // Offers a fill for a login field the person just reached.
      function consider(el) {
        if (!el || el.tagName !== 'INPUT') { return; }
        var now = Date.now();
        if (lastConsidered.el === el && now - lastConsidered.at < 600) { return; }
        var pw = null, user = null;
        if (isPw(el)) { pw = el; user = usernameFor(el); }
        else if (textLike(el)) {
          var all = passwordFields(scope(el));
          if (all.length) { pw = all[0]; user = usernameFor(pw); if (user !== el) { return; } }
          else if (identifierLike(el) && visible(el) && el.value === '') {
            lastConsidered = { el: el, at: now };
            send({ kind: 'focusIdentifier', token: register(null, el), action: actionOf(el) });
            return;
          }
        }
        if (!pw || !visible(pw) || pw.value !== '') { return; }
        lastConsidered = { el: el, at: now };
        send({ kind: 'focus', token: register(pw, user), isNewPassword: isNewForm(pw), action: actionOf(pw), username: user ? user.value : '' });
      }

      window.addEventListener('pointerdown', function (ev) {
        if (!trusted(ev)) { return; }
        lastGesture = Date.now();
        // A field that already has focus (autofocus) fires no focusin when clicked, so look at the click itself.
        var t = targetOf(ev);
        if (t && t.tagName === 'INPUT') { consider(t); }
      }, true);
      window.addEventListener('keydown', function (ev) {
        if (!trusted(ev)) { return; }
        lastGesture = Date.now();
        var t = targetOf(ev);
        if (ev.key === 'ArrowDown' && t && t.tagName === 'INPUT' && t.value === '') { consider(t); }
        if (ev.key === 'Enter' && t && t.tagName === 'INPUT' && t.type !== 'checkbox' && t.type !== 'radio') { submission(t.form || document); }
      }, true);
      document.addEventListener('focusin', function (ev) {
        var el = targetOf(ev);
        if (!trusted(ev) || Date.now() - lastGesture > 1500) { return; }
        consider(el);
      }, true);
      window.addEventListener('input', function (ev) {
        var t = targetOf(ev);
        if (t && t.tagName === 'INPUT' && t.type === 'password') { knownPw.add(t); }
      }, true);

      // Which password the person set or typed: the new one on sign-up and change-password forms.
      function choosePassword(pws) {
        var hinted = pws.filter(isNewAttr)[0];
        if (hinted) { return { pw: hinted, isNew: true }; }
        if (pws.length > 1) {
          for (var i = 0; i < pws.length; i++) {
            for (var j = i + 1; j < pws.length; j++) { if (pws[i].value === pws[j].value) { return { pw: pws[j], isNew: true }; } }
          }
          return { pw: pws[pws.length - 1], isNew: true };
        }
        return { pw: pws[0], isNew: false };
      }
      function stillAbsent() {
        if (settling) { return; }
        settling = true;
        var started = Date.now(), goneSince = 0;
        (function tick() {
          var now = Date.now();
          if (passwordFields(document).length) { goneSince = 0; }
          else if (!goneSince) { goneSince = now; }
          else if (now - goneSince >= 1200) { settling = false; send({ kind: 'settled' }); return; }
          if (now - started > 25000) { settling = false; return; }
          setTimeout(tick, 300);
        })();
      }
      function submission(root) {
        var pws = passwordFields(root).filter(function (p) { return p.value !== ''; });
        if (!pws.length) { identifierSubmission(root); return; }
        var pick = choosePassword(pws);
        var user = usernameFor(pick.pw);
        var u = user ? user.value : '';
        var key = u + '\u0000' + pick.pw.value;
        var now = Date.now();
        if (lastSubmit.key === key && now - lastSubmit.at < 1500) { return; }
        lastSubmit = { key: key, at: now };
        send({ kind: 'submit', username: u, password: pick.pw.value, isNewPassword: pick.isNew, action: actionOf(pick.pw) });
        stillAbsent();
      }
      // The first step of a two-step sign-in: remember who is signing in so the password step can be matched to it.
      function identifierSubmission(root) {
        var found = inputsIn(root).filter(function (e) { return identifierLike(e) && visible(e) && e.value !== ''; })[0];
        if (!found || passwordFields(document).length) { return; }
        var key = 'id:' + found.value;
        var now = Date.now();
        if (lastSubmit.key === key && now - lastSubmit.at < 1500) { return; }
        lastSubmit = { key: key, at: now };
        send({ kind: 'identifier', username: found.value });
      }
      document.addEventListener('submit', function (ev) {
        if (trusted(ev) && ev.target && ev.target.tagName === 'FORM') { submission(ev.target); }
      }, true);

      var BUTTONLIKE = 'button, input[type=submit], input[type=button], input[type=image], [role=button]';
      var TOGGLE = /show|hide|reveal|toggle|eye|visib|peek/i;
      function clickTarget(t) {
        for (var el = t, n = 0; el && el.nodeType === 1 && n < 5; el = el.parentElement || (el.getRootNode && el.getRootNode().host), n++) {
          if (el.matches && el.matches(BUTTONLIKE)) { return el; }
          if (el.tagName === 'A') { var h = el.getAttribute('href'); return (!h || h === '#' || /^javascript:/i.test(h)) ? el : null; }
          if (el.tagName === 'INPUT' || el.tagName === 'LABEL' || el.tagName === 'SELECT' || el.tagName === 'TEXTAREA') { return null; }
          if (getComputedStyle(el).cursor === 'pointer') { return el; }
        }
        return null;
      }
      document.addEventListener('click', function (ev) {
        if (!trusted(ev)) { return; }
        var el = clickTarget(targetOf(ev));
        if (!el) { return; }
        var label = [el.getAttribute('aria-label'), el.getAttribute('title'), el.id, typeof el.className === 'string' ? el.className : '', (el.textContent || '').slice(0, 24)].join(' ');
        if (TOGGLE.test(label)) { return; }
        // The form around the button; formless logins (single-page apps): the nearest ancestor with a login field.
        var root = el.form || el.closest('form');
        if (root) {
          if (typeof root.checkValidity === 'function' && !root.checkValidity()) { return; }
        } else {
          root = el.parentElement || (el.getRootNode && el.getRootNode().host);
          while (root && root !== document.body && !passwordFields(root).length && !inputsIn(root).some(function (e) { return identifierLike(e) && e.value !== ''; })) {
            root = root.parentElement || (root.getRootNode && root.getRootNode().host);
          }
        }
        if (root) { submission(root); }
      }, true);

      // Tells native code the page has settled: a password field is (still) there, or none showed up.
      (function () {
        if (passwordFields(document).length) { send({ kind: 'loaded', hasPassword: true }); return; }
        var started = Date.now();
        (function tick() {
          if (passwordFields(document).length) { send({ kind: 'loaded', hasPassword: true }); return; }
          if (Date.now() - started >= 2500) { send({ kind: 'loaded', hasPassword: false }); return; }
          setTimeout(tick, 250);
        })();
      })();
    })();
    """#
}
