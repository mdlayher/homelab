// Merges the settings lgtv/deploy manages into Glasshouse's config.json and
// leaves every other key as the dashboard or a hand edit left it. Prints
// each managed key that differs, the token only as set or unset; with
// --check it changes nothing.
//
// Usage: node settings.js [--check] <managed.json> <token> <config.json>
//
// ES5, for the TVs' node. The file is written as Glasshouse's own settings
// writer does: two-space JSON, mode 600, renamed into place.
var fs = require('fs');

var args = process.argv.slice(2);
var check = args[0] === '--check';
if (check) args.shift();

var managed = JSON.parse(fs.readFileSync(args[0], 'utf8'));
managed.token = fs.readFileSync(args[1], 'utf8').replace(/\n$/, '');
var path = args[2];
// Glasshouse writes config.json on the first save in its dashboard and runs
// on defaults until then, so a missing file is an empty one.
var config = fs.existsSync(path) ? JSON.parse(fs.readFileSync(path, 'utf8')) : {};

function isObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function show(name, v) {
  if (v === undefined) return 'unset';
  return name === 'token' ? 'set' : JSON.stringify(v);
}

var changed = false;
function merge(dst, src, prefix) {
  Object.keys(src).forEach(function (k) {
    var name = prefix + k;
    if (isObject(src[k])) {
      if (!isObject(dst[k])) dst[k] = {};
      return merge(dst[k], src[k], name + '.');
    }
    if (JSON.stringify(dst[k]) === JSON.stringify(src[k])) return;
    console.log(path + ': ' + name + ': ' + show(name, dst[k]) + ' -> ' + show(name, src[k]));
    dst[k] = src[k];
    changed = true;
  });
}
merge(config, managed, '');

if (changed && !check) {
  var tmp = path + '.deploy';
  fs.writeFileSync(tmp, JSON.stringify(config, null, 2), 'utf8');
  fs.chmodSync(tmp, parseInt('600', 8));
  fs.renameSync(tmp, path);
}
