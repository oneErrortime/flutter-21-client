#!/usr/bin/env node
// prebuild/generate-docs.js
// Reads all .md files from docs/content/ and generates docs/docs.json
// Mirrors the approach used by sliver-docs

const fs = require('fs');
const path = require('path');

const contentDir = path.join(__dirname, '..', 'content');
const outputFile = path.join(__dirname, '..', 'docs.json');

function generateDocs() {
  if (!fs.existsSync(contentDir)) {
    console.error('[prebuild] content/ directory not found');
    process.exit(1);
  }

  const files = fs.readdirSync(contentDir)
    .filter(f => f.endsWith('.md'))
    .sort();

  const docs = files.map(file => {
    const filePath = path.join(contentDir, file);
    const content = fs.readFileSync(filePath, 'utf8');
    const name = path.basename(file, '.md');
    return { name, content };
  });

  fs.writeFileSync(outputFile, JSON.stringify({ docs }, null, 2));
  console.log(`[prebuild] Generated docs.json with ${docs.length} documents:`);
  docs.forEach(d => console.log(`  • ${d.name}`));
}

generateDocs();
