/* SF Symbol stand-ins. Each <svg> carries data-sf-symbol="<real SF Symbol name>".
   In SwiftUI use Image(systemName: <name>) — these drawings are placeholders only.
   "_spinner" = ProgressView().controlSize(.small). */
(function () {
  var F = { fill: 'currentColor', stroke: 'none' };
  var W = { stroke: '#fff' };
  var WF = { fill: '#fff', stroke: 'none' };
  function a(b, x) { var o = {}; for (var k in b) o[k] = b[k]; for (var j in (x || {})) o[j] = x[j]; return o; }
  function p(d, x) { return ['path', a({ d: d }, x)]; }
  function c(cx, cy, r, x) { return ['circle', a({ cx: cx, cy: cy, r: r }, x)]; }
  function r(x0, y, w, h, rx, x) { return ['rect', a({ x: x0, y: y, width: w, height: h, rx: rx }, x)]; }
  var shield = 'M10 1.8 3.6 4.3v5.1c0 3.9 2.7 7.1 6.4 8.8 3.7-1.7 6.4-4.9 6.4-8.8V4.3z';
  var star = 'M10 2.3l2.35 4.9 5.35.65-3.95 3.7 1 5.3L10 14.2l-4.75 2.65 1-5.3-3.95-3.7 5.35-.65z';
  var bell = 'M5 13.8V9a5 5 0 0 1 10 0v4.8l1.5 1.7h-13z';
  var oct = 'M7 2h6l5 5v6l-5 5H7l-5-5V7z';
  var tri = 'M10 2.4c.4 0 .8.2 1 .6l7.2 12.6c.4.8-.1 1.7-1 1.7H2.8c-.9 0-1.4-.9-1-1.7L9 3c.2-.4.6-.6 1-.6z';
  var box = 'M6.5 8H5v8.5h10V8h-1.5';
  var teeth = [0, 45, 90, 135, 180, 225, 270, 315].map(function (d) {
    var t = d * Math.PI / 180;
    return p('M' + (10 + 5.4 * Math.cos(t)).toFixed(2) + ' ' + (10 + 5.4 * Math.sin(t)).toFixed(2) + 'L' + (10 + 7.6 * Math.cos(t)).toFixed(2) + ' ' + (10 + 7.6 * Math.sin(t)).toFixed(2), { strokeWidth: 2.4 });
  });
  var spin = [0, 1, 2, 3, 4, 5, 6, 7].map(function (i) {
    var t = (i * 45 - 90) * Math.PI / 180;
    return p('M' + (10 + 4 * Math.cos(t)).toFixed(2) + ' ' + (10 + 4 * Math.sin(t)).toFixed(2) + 'L' + (10 + 7.5 * Math.cos(t)).toFixed(2) + ' ' + (10 + 7.5 * Math.sin(t)).toFixed(2), { strokeWidth: 2, opacity: (0.2 + i * 0.1).toFixed(2) });
  });
  var I = {
    'arrow.clockwise': [p('M16 10a6 6 0 1 1-1.76-4.24'), p('M14.8 2.6v3.6h-3.6')],
    'square.and.arrow.down': [p(box), p('M10 2.5v9'), p('M7 8.5l3 3 3-3')],
    'square.and.arrow.up': [p(box), p('M10 12V2.5'), p('M7 5.5l3-3 3 3')],
    'checkmark.shield.fill': [p(shield, F), p('M7 10l2.2 2.2L13.3 8', W)],
    'shield.slash': [p(shield), p('M3 3l14 14')],
    'lock.shield.fill': [p(shield, F), r(7.3, 9.3, 5.4, 4.2, 0.8, WF), p('M8.4 9.3V8.2a1.6 1.6 0 0 1 3.2 0v1.1', a(W, { strokeWidth: 1.3 }))],
    'lock.fill': [r(4.5, 8.5, 11, 8.5, 1.8, F), p('M6.8 8.5V6.2a3.2 3.2 0 0 1 6.4 0v2.3')],
    'xmark.octagon.fill': [p(oct, F), p('M7.5 7.5l5 5M12.5 7.5l-5 5', W)],
    'exclamationmark.triangle.fill': [p(tri, F), p('M10 7.3v4.6', W), c(10, 14.3, 1, WF)],
    'exclamationmark.circle': [c(10, 10, 7.6), p('M10 6v5'), c(10, 13.9, 0.95, F)],
    'checkmark.circle.fill': [c(10, 10, 8, F), p('M6.5 10.2l2.4 2.4 4.6-5', W)],
    'info.circle.fill': [c(10, 10, 8, F), p('M10 9v5', W), c(10, 6.3, 1, WF)],
    'clock.fill': [c(10, 10, 8, F), p('M10 5.5V10l3 2', W)],
    'questionmark.circle': [c(10, 10, 7.6), p('M7.8 7.6a2.3 2.3 0 1 1 3.3 2.1c-.7.4-1.1.9-1.1 1.7v.4'), c(10, 14.3, 0.95, F)],
    'star': [p(star)],
    'star.fill': [p(star, F)],
    'bell': [p(bell), p('M8.3 17.6a1.8 1.8 0 0 0 3.4 0')],
    'bell.fill': [p(bell, F), p('M8.3 17.6a1.8 1.8 0 0 0 3.4 0')],
    'plus': [p('M10 4v12M4 10h12')],
    'checkmark': [p('M4.5 10.5l3.5 3.5 7.5-8')],
    'line.3.horizontal.decrease.circle': [c(10, 10, 7.6), p('M6.3 7.6h7.4M7.6 10h4.8M8.9 12.4h2.2')],
    'magnifyingglass': [c(8.5, 8.5, 5), p('M12.3 12.3l4.2 4.2')],
    'doc.on.doc': [r(7, 6, 9, 11, 1.6), p('M13 6V4.6A1.6 1.6 0 0 0 11.4 3H5.6A1.6 1.6 0 0 0 4 4.6v8A1.6 1.6 0 0 0 5.6 14.2H7')],
    'chevron.up.chevron.down': [p('M7 8l3-3 3 3M7 12l3 3 3-3')],
    'chevron.down': [p('M5.5 8l4.5 4.5L14.5 8')],
    'chevron.right': [p('M8 5.5l4.5 4.5L8 14.5')],
    'xmark': [p('M5.5 5.5l9 9M14.5 5.5l-9 9')],
    'globe': [c(10, 10, 7.8), ['ellipse', { cx: 10, cy: 10, rx: 3.4, ry: 7.8 }], p('M2.2 10h15.6')],
    'network': [c(10, 4.2, 2), c(4.2, 15.8, 2), c(15.8, 15.8, 2), p('M10 6.2v4.3M10 10.5 5.4 14.2M10 10.5l4.6 3.7')],
    'wifi': [p('M2.8 8a10.2 10.2 0 0 1 14.4 0'), p('M5.4 10.7a6.5 6.5 0 0 1 9.2 0'), p('M8 13.4a2.8 2.8 0 0 1 4 0'), c(10, 16.2, 1.1, F)],
    'arrow.down.circle.fill': [c(10, 10, 8, F), p('M10 5.6v7.6M6.9 10.4 10 13.5l3.1-3.1', W)],
    'arrow.down.circle': [c(10, 10, 7.6), p('M10 5.8v7.4M7 10.4l3 3 3-3')],
    'gearshape': [c(10, 10, 5.4)].concat(teeth).concat([c(10, 10, 2.2)]),
    'folder': [p('M2.5 5.5A1.5 1.5 0 0 1 4 4h3.5l1.7 1.8H16a1.5 1.5 0 0 1 1.5 1.5v7.2A1.5 1.5 0 0 1 16 16H4a1.5 1.5 0 0 1-1.5-1.5z')],
    'wrench.and.screwdriver': [p('M12.8 3.2a3.6 3.6 0 0 0-4.5 4.6L3.4 12.7a1.6 1.6 0 0 0 2.3 2.3l4.9-4.9a3.6 3.6 0 0 0 4.6-4.5l-2.2 2.2-1.9-.4-.4-1.9z')],
    'ellipsis.circle': [c(10, 10, 7.6), c(6.6, 10, 1, F), c(10, 10, 1, F), c(13.4, 10, 1, F)],
    'lightbulb': [p('M7.6 14.6h4.8M8.2 17h3.6M10 2.5a5 5 0 0 0-3 9c.6.5 1 1.2 1 2h4c0-.8.4-1.5 1-2a5 5 0 0 0-3-9z')],
    'arrow.up.right': [p('M6 14 14 6M7.5 6H14v6.5')],
    'arrow.up.right.square': [p('M11 3.5h5.5V9M16.5 3.5 9 11M8 4.5H5A1.5 1.5 0 0 0 3.5 6v9A1.5 1.5 0 0 0 5 16.5h9a1.5 1.5 0 0 0 1.5-1.5v-3')],
    'waveform.path.ecg': [p('M2 10h3.5l2-5 3 10 2-5H18')],
    'trash': [p('M3.5 5.5h13M8 5.5V3.5h4v2M5 5.5l.8 11h8.4l.8-11M8.3 8.5v5.5M11.7 8.5v5.5')],
    'arrow.uturn.backward': [p('M7.5 5 4 8.5 7.5 12'), p('M4 8.5h8a4 4 0 0 1 0 8H9')],
    'externaldrive': [r(2.5, 6, 15, 8, 2), c(14, 10, 0.9, F)],
    'moon.fill': [p('M15.5 12.5A6.5 6.5 0 0 1 7.5 4.5a6.5 6.5 0 1 0 8 8z', F)],
    'menubar.rectangle': [r(2.5, 4, 15, 12, 2), p('M2.5 7.5h15')],
    'power': [p('M10 3v6'), p('M6.2 5.6a6 6 0 1 0 7.6 0')],
    'person.crop.circle': [c(10, 10, 7.8), c(10, 8, 2.8), p('M4.8 15.5a6.4 6.4 0 0 1 10.4 0')],
    'server.rack': [r(3, 3.5, 14, 5.5, 1.2), r(3, 11, 14, 5.5, 1.2), c(6, 6.25, 0.8, F), c(6, 13.75, 0.8, F)],
    'tray': [p('M2.5 11.5 4.8 4.5h10.4l2.3 7v4h-15z'), p('M2.5 11.5h4.2l1 2h4.6l1-2h4.2')],
    'key': [c(6.5, 13.5, 3), p('M8.6 11.4 16 4M13.5 6.5l2 2')],
    'pencil': [p('M13.5 3.5l3 3L7 16H4v-3z')],
    'bell.badge': [p(bell), p('M8.3 17.6a1.8 1.8 0 0 0 3.4 0'), c(15, 4.5, 2.2, F)],
    '_spinner': spin
  };
  function Icon(props) {
    var R = window.React;
    var name = props.sym || 'questionmark.circle';
    var size = Number(props.size || 16);
    var def = I[name] || I['questionmark.circle'];
    var spinning = name === '_spinner';
    return R.createElement('svg', {
      width: size, height: size, viewBox: '0 0 20 20', fill: 'none', stroke: 'currentColor',
      strokeWidth: 1.6, strokeLinecap: 'round', strokeLinejoin: 'round',
      'data-sf-symbol': spinning ? 'ProgressView' : name, 'aria-hidden': 'true', focusable: 'false',
      style: { display: 'block', flex: 'none', overflow: 'visible', color: props.color, animation: spinning ? 'pi-spin 0.9s steps(8) infinite' : undefined }
    }, def.map(function (d, i) { return R.createElement(d[0], a({ key: i }, d[1])); }));
  }
  window.Icon = Icon;
  window.PI_SYMBOLS = Object.keys(I);
  if (typeof module !== 'undefined' && module.exports) module.exports = { Icon: Icon, SYMBOLS: Object.keys(I) };
})();
