#!/usr/bin/env node
'use strict';

const util = require('util');
const exec = util.promisify(require('child_process').exec);
const yargs = require('yargs');
const process = require('process');
const fs = require('fs');
const path = require('path');
const { prompt } = require('enquirer');

const binaryExtensions = ['.png', '.caf'];

const copyBinaryFile = (srcPath, destPath) => {
  return new Promise((resolve, reject_) => {
    let rejected = false;
    const reject = (err) => {
      if (!rejected) {
        reject_(err);
        rejected = true;
      }
    };
    const srcPermissions = fs.statSync(srcPath).mode;
    const readStream = fs.createReadStream(srcPath);
    readStream.on('error', function(err) {
      reject(err);
    });
    const writeStream = fs.createWriteStream(destPath, {
      mode: srcPermissions
    });
    writeStream.on('error', function(err) {
      reject(err);
    });
    writeStream.on('close', function(ex) {
      if (!rejected) {
        resolve();
      }
    });
    readStream.pipe(writeStream);
  });
};

const applyReplacements = (replacements, dest) => {
  Object.keys(replacements).forEach(
    regex =>
      dest = dest.replace(new RegExp(regex, 'g'), replacements[regex])
  );
  return dest;
 };

const copyAndReplace = (srcPath, destPath, replacements) => {
  const extension = path.extname(srcPath);
  if (binaryExtensions.indexOf(extension) !== -1) {
    return copyBinaryFile(srcPath, destPath);
  } else {
    const srcPermissions = fs.statSync(srcPath).mode;
    const content = applyReplacements(
      replacements,
      fs.readFileSync(srcPath, 'utf8'),
    );
    fs.writeFileSync(destPath, content, {
      encoding: 'utf8',
      mode: srcPermissions,
    });
    return Promise.resolve();
  }
};

const walk = (original) => {
  const go = (current) => {
    const thisPath = {
      src: current,
      dest: current.substring(original.length + 1)
    };


    if (!fs.lstatSync(current).isDirectory()) {
      return [thisPath];
    }

    const files = fs.readdirSync(current).map(child => {
      child = path.join(current, child);
      return go(child);
    });

    return [].concat.apply([], files);
  };
  return go(original);
};

const createFromTemplate = (templatePath, destPath, replacements) => {
  return Promise.all(walk(templatePath).map(({src, dest: dest_}) => {
    const dest = path.join(destPath, applyReplacements(replacements, dest_));
    if (!fs.existsSync(path.dirname(dest))) {
      fs.mkdirSync(path.dirname(dest), {recursive: true});
    }

    return copyAndReplace(src, dest, replacements);
  }));
};

const getReplacements = (options, initial) => {
  return options.map(({prompt: prompt_, valid, key}) => {
      return dict => {
        const question = {
          type: 'input',
          name: 'key',
          message: `What is ${prompt_} (/${valid}/)?`,
          validate: (x) => {
            return x.match(new RegExp(`^${valid}\$`)) !== null;
          }
        };

        return prompt(question).then(answer => {
          dict[key] = answer.key;
          return dict;
        });
      };
  }).reduce((prev, next) => {
    return prev.then(next);
  }, Promise.resolve(initial));
};

const templateOptions = [
{
  prompt: "the short name of the project (used in code)",
  valid: "[a-zA-Z0-9]+",
  key: "\\$PROJ_NAME\\$",
  argname: 'name',
  yargs: {
    alias: 'n'
  }
},
{
  prompt: "Company identifier for bundles (e.g., com.MyCompany)",
  valid: "[a-zA-Z0-9\\.]+",
  key: "\\$IDENT\\$",
  argname: 'identifier',
  yargs: {
    alias: 'i'
  }
},
{
  prompt: "AU manufacturer code (four letters)",
  valid: "[a-zA-Z0-9 ]{4}",
  key: "\\$MANU\\$",
  argname: 'manufacturer',
  yargs: {
    alias: 'm'
  }
},
{
  prompt: "AU subtype code (four letters)",
  valid: "[a-zA-Z0-9 ]{4}",
  key: "\\$AUTYPE\\$",
  argname: 'autype',
  yargs: {
    alias: 'a'
  }
},
{
  prompt: "AU manufacturer (user-visible)",
  valid: "[a-zA-Z0-9 ]+",
  key: "\\$MANULONG\\$",
  argname: 'manufacturer-long',
  yargs: {}
},
{
  prompt: "AU name (user-visible)",
  valid: "[a-zA-Z0-9 ]+",
  key: "\\$AUTYPELONG\\$",
  argname: 'autype-long',
  yargs: {}
},
];

const argv = yargs.command("$0 <destination>", "Create a new brinicle project", (builder) => {
  let built = builder.positional("destination", {
    describe: "Where to generate the project",
  });
  templateOptions.forEach(({prompt, valid, argname, yargs}) => {
    yargs.describe = `prompt (/${valid}/)`;
    yargs.check = x => {
            return x.match(new RegExp(`^${valid}\$`)) !== null;
    };
    built = built.option(argname, yargs);
  });
}, (argv) => {
  const dest = argv.destination;

  if (fs.existsSync(dest)) {
    console.error(`Destination ${dest} already exists!`);
    process.exit(1);
  }

  // special case - name is the dest if the dest matches.
  if (!argv.name && dest.match(new RegExp(`^${templateOptions[0].valid}\$`))) {
    argv.name = dest;
  }

  const initial = {};

  const unsetOptions = templateOptions.filter(({argname, key}) => {
    if (argv[argname]) {
      initial[key] = argv[argname];
      return false;
    }
    return true;
  });

  getReplacements(unsetOptions, initial)
    .then(replacements => {
      return createFromTemplate(
        path.join(__dirname, "template"),
        path.join(process.cwd(), dest),
        replacements);
    }).then(() => {
      return exec('npm install', {
        cwd: process.cwd() + "/" +  dest + "/mac"
      });
    });
}).argv;

