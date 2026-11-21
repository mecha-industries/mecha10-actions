const fs = require('fs');

const reportPath = process.env.DANGER_REPORT_FILE;
if (reportPath && fs.existsSync(reportPath)) {
  markdown(fs.readFileSync(reportPath, 'utf8'));
}
