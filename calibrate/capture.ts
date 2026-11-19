// Shoot one static scene through every film simulation with neutral settings, saving RAW + in-camera JPEG pairs.
// Usage: bun capture.ts <scene> [chartPage]
//   With chartPage, tells serve.ts to show that chart page first.
import { $ } from "bun";

const SIMS = {
  provia: 1, velvia: 2, astia: 3, proneghi: 4, pronegstd: 5, mono: 6, classicchrome: 11,
  acros: 12, eterna: 16, classicneg: 17, bleach: 18, nostalgic: 19, reala: 20,
} as const;

// Everything that isn't the film simulation is pinned so the pair isolates the sim.
const NEUTRAL: readonly string[] = [
  "/main/other/d320=0", // highlight
  "/main/other/d321=0", // shadow
  "/main/other/d008=0", // color
  "/main/other/5015=0", // sharpness
  "/main/other/d01c=8192", // NR 0
  "/main/other/d023=1", // grain off
  "/main/other/d007=100", // DR100: no hidden tone changes
  "/main/other/5005=4", // WB daylight (fixed)
  "/main/other/d00b=0",
  "/main/other/d00c=0",
  "/main/capturesettings/exposurecompensation=0",
  "/main/imgsettings/imageformat=RAW + JPEG Fine",
];

const [scene, page] = Bun.argv.slice(2);
if (!scene) {
  console.error("usage: bun capture.ts <scene> [chartPage]");
  process.exit(2);
}
const dir = `${import.meta.dir}/captures/${scene}`;
await $`mkdir -p ${dir}`;
const gp = async (args: string[]): Promise<void> => {
  await $`pkill -9 -f ptpcamerad`.nothrow().quiet();
  await $`gphoto2 ${args}`.quiet();
};

if (page) {
  await fetch(`http://localhost:${process.env.PORT ?? 8799}/page/${page}`, { method: "POST" });
  await Bun.sleep(1200);
}
await gp(NEUTRAL.flatMap((a) => ["--set-config", a]));
// Focus once, then hold it so every sim sees an identical frame.
await gp(["--set-config", "/main/capturesettings/focusmode=Single-Servo AF"]); // handheld: refocus each shot

for (const [name, code] of Object.entries(SIMS)) {
  await gp(["--set-config", `/main/other/d001=${code}`]);
  await gp(["--capture-image-and-download", "--force-overwrite", "--filename", `${dir}/${name}.%C`]);
  console.log(`${scene}: ${name}`);
}
await gp(["--set-config", "/main/capturesettings/focusmode=Single-Servo AF"]);
console.log(`done ${dir}`);
