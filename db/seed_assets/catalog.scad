// Printwright demo catalog — self-authored parametric models, dedicated CC0-1.0.
// Generate with: scripts/generate_seed_assets.sh

$fn = 64;
model = "calibration-cube";

module rounded_box(size, radius) {
  translate([radius, radius, radius])
    minkowski() {
      cube([size[0] - 2 * radius, size[1] - 2 * radius, size[2] - 2 * radius]);
      sphere(r = radius, $fn = 24);
    }
}

module phone_stand() {
  // Flat base, two triangulated back ribs, and a retaining lip.
  union() {
    cube([76, 66, 4]);
    translate([0, 5, 4]) cube([76, 6, 13]);
    for (x = [8, 62])
      hull() {
        translate([x, 43, 4]) cube([6, 14, 3]);
        translate([x, 48, 4]) rotate([0, 0, 0]) cube([6, 5, 54]);
      }
    translate([8, 48, 4]) cube([60, 5, 8]);
  }
}

module cable_clip() {
  // Springy open ring on a broad adhesive/screw-free desk pad.
  linear_extrude(height = 12)
    union() {
      translate([-14, -10]) square([28, 7]);
      difference() {
        circle(r = 13);
        circle(r = 8);
        translate([-3.8, 3]) square([7.6, 14]);
      }
    }
}

module planter() {
  difference() {
    cylinder(h = 64, r1 = 33, r2 = 27, $fn = 72);
    translate([0, 0, 3]) cylinder(h = 64, r1 = 29, r2 = 23, $fn = 72);
    translate([0, 0, -1]) cylinder(h = 6, r = 3.2, $fn = 28);
  }
}

module pip(x, y, z, face) {
  if (face == "top") translate([x, y, z]) sphere(r = 2.25, $fn = 20);
  if (face == "front") translate([x, y, z]) sphere(r = 2.25, $fn = 20);
  if (face == "right") translate([x, y, z]) sphere(r = 2.25, $fn = 20);
}

module dice() {
  // Rounded 24 mm die with 1/2/3 recessed faces visible from the print orientation.
  difference() {
    rounded_box([24, 24, 24], 1.7);
    pip(12, 12, 23.4, "top");
    for (x = [7, 17]) pip(x, -0.4, 12, "front");
    for (p = [[23.4, 7, 7], [23.4, 12, 12], [23.4, 17, 17]])
      pip(p[0], p[1], p[2], "right");
  }
}

module bag_hook() {
  // Open, flat carabiner-style hook; the tapered mouth flexes in PETG.
  linear_extrude(height = 8)
    difference() {
      union() {
        difference() {
          circle(r = 26, $fn = 96);
          circle(r = 18, $fn = 96);
        }
        translate([-26, -5]) square([18, 10]);
      }
      translate([8, 5]) rotate(30) square([28, 10]);
    }
}

module vase() {
  // Twisted twelve-sided shell, with a closed 2.4 mm floor.
  difference() {
    linear_extrude(height = 105, twist = 105, slices = 105, scale = 0.72)
      circle(r = 29, $fn = 12);
    translate([0, 0, 2.4])
      linear_extrude(height = 104, twist = 105, slices = 105, scale = 0.72)
        circle(r = 26.2, $fn = 12);
  }
}

module gear() {
  teeth = 14;
  tooth_points = [
    for (i = [0 : teeth * 4 - 1])
      let(a = i * 360 / (teeth * 4), r = (i % 4 == 1 || i % 4 == 2) ? 25 : 21)
        [r * cos(a), r * sin(a)]
  ];
  linear_extrude(height = 9)
    difference() {
      polygon(tooth_points);
      circle(r = 5.2, $fn = 32);
      for (a = [0 : 60 : 300]) translate([13 * cos(a), 13 * sin(a)]) circle(r = 3.1, $fn = 24);
    }
}

module wall_bracket() {
  // One-piece L bracket with two wall holes and a gusset on each side.
  difference() {
    union() {
      cube([52, 6, 58]);
      cube([52, 48, 6]);
      for (x = [3, 43])
        translate([x, 6, 6]) rotate([90, 0, 90])
          linear_extrude(height = 6) polygon([[0, 0], [35, 0], [0, 42]]);
    }
    for (x = [15, 37])
      translate([x, -1, 39]) rotate([-90, 0, 0]) cylinder(h = 8, r = 3.3, $fn = 30);
  }
}

module whistle() {
  // Pealess signal-whistle prototype: mouth airway feeds a resonant chamber and edge.
  difference() {
    union() {
      hull() {
        translate([0, 0, 10]) rotate([90, 0, 0]) cylinder(h = 18, r = 10, center = true);
        translate([38, 0, 10]) cube([22, 18, 20], center = true);
      }
      translate([-10, 0, 10]) rotate([90, 0, 0]) cylinder(h = 18, r = 5, center = true);
    }
    // Resonant chamber and sound window.
    translate([-1, 0, 11]) rotate([90, 0, 0]) cylinder(h = 12, r = 6.3, center = true);
    translate([4, -7, 11]) cube([18, 14, 11]);
    // Straight mouth airway, ending at a sharp ramp.
    translate([18, -6, 11.5]) cube([32, 12, 4]);
    translate([8, -7, 10]) rotate([0, -20, 0]) cube([14, 14, 5]);
    // Lanyard hole.
    translate([-10, 0, 10]) rotate([90, 0, 0]) cylinder(h = 22, r = 2.3, center = true, $fn = 24);
  }
}

module beaver() {
  // Single-piece desk mascot: body, head, tail, feet, ears, muzzle, eyes and hat.
  union() {
    translate([0, 0, 21]) scale([1.05, 0.78, 1.2]) sphere(r = 17, $fn = 48);
    translate([0, 0, 49]) scale([1, 0.86, 0.9]) sphere(r = 15, $fn = 48);
    translate([0, 14, 43]) scale([1, 0.45, 0.58]) sphere(r = 9, $fn = 36);
    for (x = [-6, 6]) translate([x, 12, 51]) sphere(r = 1.8, $fn = 20);
    for (x = [-11, 11]) translate([x, 0, 59]) sphere(r = 4, $fn = 28);
    for (x = [-10, 10]) translate([x, 5, 3.6]) scale([1.4, 1.8, 0.6]) sphere(r = 6, $fn = 32);
    translate([0, -18, 4]) scale([0.72, 1.3, 0.18]) sphere(r = 15, $fn = 40);
    translate([0, 0, 62]) cylinder(h = 3, r = 13, $fn = 48);
    translate([0, 0, 64]) cylinder(h = 12, r = 8.5, $fn = 48);
  }
}

module calibration_cube() {
  // Exact nominal envelope, chamfered only 0.6 mm to reduce elephant-foot ambiguity.
  rounded_box([20, 20, 20], 0.6);
}

module hex_organizer() {
  // Open hex cup with a 3 mm floor and 2.6 mm walls.
  difference() {
    cylinder(h = 72, r = 34, $fn = 6);
    translate([0, 0, 3]) cylinder(h = 72, r = 28.8, $fn = 6);
  }
}

color("#e26d5a") {
  if (model == "phone-stand") rotate([0, 0, 180]) phone_stand();
  else if (model == "cable-clip") cable_clip();
  else if (model == "planter-mini") planter();
  else if (model == "dice-d6") dice();
  else if (model == "bag-hook") bag_hook();
  else if (model == "vase-spiral") vase();
  else if (model == "gear-toy") gear();
  else if (model == "wall-bracket") wall_bracket();
  else if (model == "whistle") whistle();
  else if (model == "beaver-with-hat") rotate([0, 0, 180]) beaver();
  else if (model == "calibration-cube") calibration_cube();
  else if (model == "hex-organizer") hex_organizer();
}
