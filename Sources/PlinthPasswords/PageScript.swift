import Foundation
import WebKit

/// The script that finds login forms. It runs in its own content world ("PlinthPasswords"): the page's scripts
/// cannot see its variables, call its fill function or read the messages it posts.
///
/// It reports four things to native code and never decides anything itself:
///  - `focus`: the person clicked or tabbed into a login field (only after a real pointer or key event, so a page
///    cannot trigger a fill by calling `focus()`);
///  - `submit`: a login form was submitted, with what was typed;
///  - `loaded` / `settled`: a document finished loading, or (single-page apps) the form went away after a submit,
///    which is how native code tells a successful login from a failed one.
/// The only way back in is `fill`, called by native code with the secret as an argument.
public enum PasswordPageScript {
    public static let handlerName = "plinthPasswords"
    public static let world = WKContentWorld.world(name: "PlinthPasswords")

    public static func userScript() -> WKUserScript {
        // Main frame only: logins in embedded frames are never captured or filled.
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
    }

    /// The JavaScript that fills field values; run through `callAsyncJavaScript` with these argument names.
    public static let fillBody = "return window.__plinthPwFill(token, username, password);"

    static let source = """
    (function () {
      if (window.__plinthPw) { return; }
      window.__plinthPw = true;
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      if (!handler) { return; }
      var entries = {};
      var nextToken = 1;
      var lastGesture = 0;
      var lastSubmit = { key: '', at: 0 };

      function visible(el) {
        if (!el || !el.isConnected) { return false; }
        var r = el.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) { return false; }
        var s = getComputedStyle(el);
        return s.visibility !== 'hidden' && s.display !== 'none';
      }
      function scope(el) { return el.form || document; }
      function passwordFields(root) {
        return Array.prototype.filter.call(root.querySelectorAll('input[type=password]'), visible);
      }
      function isNew(el) { return /new-password/i.test(el.getAttribute('autocomplete') || ''); }
      function textLike(el) {
        var t = (el.getAttribute('type') || 'text').toLowerCase();
        return t === 'text' || t === 'email' || t === 'tel' || t === 'url';
      }
      function usernameFor(pw) {
        var inputs = Array.prototype.slice.call(scope(pw).querySelectorAll('input'));
        var i = inputs.indexOf(pw);
        for (var j = i - 1; j >= 0; j--) {
          if (textLike(inputs[j]) && visible(inputs[j])) { return inputs[j]; }
        }
        return null;
      }
      function register(pw, user) {
        for (var k in entries) { if (entries[k].pw === pw) { entries[k].user = user; return Number(k); } }
        var token = nextToken++;
        entries[token] = { pw: pw, user: user };
        return token;
      }
      function actionOf(pw) { return pw.form ? (pw.form.getAttribute('action') ? pw.form.action : '') : ''; }
      function send(body) { try { handler.postMessage(body); } catch (e) {} }

      function setValue(el, value) {
        if (!el || !el.isConnected) { return; }
        var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        setter.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
      // Called by native code only, with the login the person chose.
      window.__plinthPwFill = function (token, username, password) {
        var e = entries[token];
        if (!e || !e.pw || !e.pw.isConnected) { return false; }
        if (e.user && username !== '') { setValue(e.user, username); }
        setValue(e.pw, password);
        return true;
      };

      ['pointerdown', 'keydown'].forEach(function (type) {
        window.addEventListener(type, function (ev) { if (ev.isTrusted) { lastGesture = Date.now(); } }, true);
      });

      document.addEventListener('focusin', function (ev) {
        var el = ev.target;
        if (!ev.isTrusted || !el || el.tagName !== 'INPUT' || Date.now() - lastGesture > 1000) { return; }
        var pw = null, user = null;
        if (el.type === 'password') { pw = el; user = usernameFor(el); }
        else if (textLike(el)) {
          var all = passwordFields(scope(el));
          if (all.length) { pw = all[0]; user = usernameFor(pw); if (user !== el) { return; } }
        }
        if (!pw || !visible(pw) || pw.value !== '') { return; }
        send({ kind: 'focus', token: register(pw, user), isNewPassword: isNew(pw), action: actionOf(pw) });
      }, true);

      function submission(root, origin) {
        var pws = passwordFields(root).filter(function (p) { return p.value !== ''; });
        if (!pws.length) { return; }
        var pw = pws.filter(isNew)[0] || pws[0];
        var user = usernameFor(pw);
        var u = user ? user.value : '';
        var key = u + '\\u0000' + pw.value;
        var now = Date.now();
        if (lastSubmit.key === key && now - lastSubmit.at < 1500) { return; }
        lastSubmit = { key: key, at: now };
        send({ kind: 'submit', username: u, password: pw.value, isNewPassword: pws.some(isNew), action: actionOf(pw) });
        setTimeout(function () { if (!passwordFields(document).length) { send({ kind: 'settled' }); } }, 1800);
      }
      document.addEventListener('submit', function (ev) {
        if (ev.isTrusted && ev.target && ev.target.tagName === 'FORM') { submission(ev.target); }
      }, true);
      document.addEventListener('click', function (ev) {
        var el = ev.target && ev.target.closest ? ev.target.closest('button, input[type=submit], input[type=button], [role=button], a') : null;
        if (!ev.isTrusted || !el) { return; }
        // Formless logins (single-page apps): the nearest ancestor that holds a password field.
        var root = el.form || el.closest('form');
        if (!root) { root = el.parentElement; while (root && !passwordFields(root).length && root !== document.body) { root = root.parentElement; } }
        if (root && passwordFields(root).length) { submission(root); }
      }, true);
      document.addEventListener('keydown', function (ev) {
        if (!ev.isTrusted || ev.key !== 'Enter' || !ev.target || ev.target.type !== 'password') { return; }
        submission(ev.target.form || document);
      }, true);

      send({ kind: 'loaded', hasPassword: passwordFields(document).length > 0 });
    })();
    """
}
