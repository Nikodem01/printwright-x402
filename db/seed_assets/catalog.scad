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

module headphone_stand() {
  union() {
    cube([80, 70, 6]);
    translate([34, 29, 6]) cube([12, 12, 124]);
    translate([5, 24, 130]) cube([70, 22, 12]);
  }
}

module pen_tray() {
  difference() {
    cube([160, 65, 16]);
    translate([3, 3, 3]) cube([154, 59, 15]);
  }
}

module cable_comb() {
  union() {
    cube([90, 25, 6]);
    for (x = [10, 26, 42, 58, 74]) translate([x, 0, 6]) cube([6, 25, 20]);
  }
}

module label_clip() {
  linear_extrude(height = 8)
    difference() {
      square([60, 22]);
      translate([4, 5]) square([52, 12]);
      translate([55, 5]) square([6, 12]);
    }
}

module soap_dish() {
  difference() {
    cube([110, 70, 12]);
    for (x = [20, 40, 60, 80, 100], y = [20, 50])
      translate([x, y, -1]) cylinder(h = 14, r = 4, $fn = 28);
  }
}

module plant_trellis() {
  linear_extrude(height = 4)
    union() {
      difference() {
        square([100, 140]);
        translate([6, 6]) square([88, 128]);
      }
      translate([47, 0]) square([6, 140]);
      for (y = [35, 70, 105]) translate([0, y]) square([100, 5]);
    }
}

module tealight_lantern() {
  difference() {
    cylinder(h = 80, r = 38, $fn = 72);
    translate([0, 0, 3]) cylinder(h = 79, r = 34, $fn = 72);
    for (z = [27, 53], a = [0 : 45 : 135])
      rotate([0, 0, a]) translate([0, 0, z]) rotate([0, 90, 0])
        cylinder(h = 90, r = 5, center = true, $fn = 28);
  }
}

module picture_stand() {
  union() {
    cube([100, 65, 5]);
    translate([0, 0, 5]) cube([100, 8, 11]);
    hull() {
      translate([0, 50, 5]) cube([100, 8, 5]);
      translate([0, 58, 80]) cube([100, 5, 5]);
    }
  }
}

module card_holder() {
  union() {
    cube([90, 50, 5]);
    translate([0, 5, 5]) cube([90, 6, 15]);
    translate([0, 39, 5]) cube([90, 6, 15]);
  }
}

module plant_saucer() {
  difference() {
    cylinder(h = 8, r = 36, $fn = 72);
    translate([0, 0, 3]) cylinder(h = 6, r = 31, $fn = 72);
  }
}

module measuring_scoop() {
  union() {
    difference() {
      cylinder(h = 25, r = 25, $fn = 72);
      translate([0, 0, 3]) cylinder(h = 24, r = 21, $fn = 72);
    }
    translate([20, -8, 4]) cube([85, 16, 8]);
  }
}

module bag_sealer() {
  linear_extrude(height = 8)
    difference() {
      square([160, 20]);
      translate([6, 5]) square([150, 10]);
      translate([155, 4]) square([6, 12]);
    }
}

module hex_coaster() {
  difference() {
    cylinder(h = 4, r = 45, $fn = 6);
    translate([0, 0, 2]) cylinder(h = 3, r = 38, $fn = 6);
  }
}

module mini_funnel() {
  difference() {
    cylinder(h = 70, r1 = 10, r2 = 42, $fn = 72);
    translate([0, 0, 3]) cylinder(h = 69, r1 = 7, r2 = 39, $fn = 72);
    translate([0, 0, -1]) cylinder(h = 8, r = 7, $fn = 36);
  }
}

module tube_squeezer() {
  linear_extrude(height = 8)
    difference() {
      square([100, 45]);
      translate([10, 17]) square([75, 5]);
      translate([91, 31]) circle(r = 5, $fn = 28);
    }
}

module spacer_set() {
  for (spec = [[8, 8, 3], [29, 9, 4], [50, 10, 5]])
    translate([spec[0], 10, 0])
      difference() {
        cylinder(h = 8, r = spec[1], $fn = 36);
        translate([0, 0, -1]) cylinder(h = 10, r = spec[2], $fn = 28);
      }
}

module corner_jig() {
  linear_extrude(height = 12)
    difference() {
      union() {
        square([80, 15]);
        square([15, 80]);
      }
      translate([7.5, 35]) circle(r = 3, $fn = 28);
      translate([35, 7.5]) circle(r = 3, $fn = 28);
    }
}

module drill_guide() {
  difference() {
    cube([80, 30, 18]);
    for (spec = [[15, 2], [40, 3], [65, 4]])
      translate([spec[0], 15, -1]) cylinder(h = 20, r = spec[1], $fn = 32);
  }
}

module star_knob() {
  linear_extrude(height = 14)
    difference() {
      union() {
        circle(r = 16, $fn = 48);
        for (a = [0 : 45 : 315]) translate([16 * cos(a), 16 * sin(a)]) circle(r = 8, $fn = 32);
      }
      circle(r = 3, $fn = 28);
    }
}

module hinge_pin() {
  union() {
    cylinder(h = 60, r = 5, $fn = 36);
    translate([0, 0, 60]) cylinder(h = 4, r = 9, $fn = 48);
  }
}

module furniture_foot() {
  union() {
    cylinder(h = 25, r1 = 25, r2 = 22, $fn = 72);
    translate([0, 0, 25]) cylinder(h = 15, r = 10, $fn = 48);
  }
}

module hose_adapter() {
  difference() {
    union() {
      cylinder(h = 30, r = 18, $fn = 64);
      translate([0, 0, 30]) cylinder(h = 30, r = 14, $fn = 64);
    }
    translate([0, 0, -1]) cylinder(h = 62, r = 9, $fn = 48);
  }
}

module puzzle_tile() {
  linear_extrude(height = 5)
    difference() {
      union() {
        square([60, 60]);
        translate([30, 60]) circle(r = 6, $fn = 32);
        translate([60, 30]) circle(r = 6, $fn = 32);
      }
      translate([30, 0]) circle(r = 6, $fn = 32);
      translate([0, 30]) circle(r = 6, $fn = 32);
    }
}

module spinning_top() {
  rotate_extrude($fn = 72)
    polygon([[0, 0], [2, 0], [25, 18], [18, 32], [6, 38], [6, 50], [0, 50]]);
}

module open_wheel_toy_racer() {
  // A compact, logo-free open-wheel desk toy. Every part meets
  // the bed or intersects the chassis, so it prints as one support-free piece.
  union() {
    difference() {
      hull() {
        translate([-38, -13, 6]) cube([29, 26, 8]);
        translate([27, -6, 6]) cube([19, 12, 6]);
      }
      // Shallow open cockpit; it stops above the floor.
      translate([-10, 0, 16]) scale([1.25, 0.82, 0.62]) sphere(r = 10, $fn = 32);
    }

    // Four short lower suspension links replace a visually implausible solid
    // beam across the chassis. Twelve-sided tyres sit on a broad print flat.
    for (x = [-30, 30]) {
      translate([x - 3, 6, 6]) cube([6, 14, 3]);
      translate([x - 3, -20, 6]) cube([6, 14, 3]);
      for (y = [-25, 25])
        translate([x, y, 9.66]) rotate([90, 0, 0]) rotate([0, 0, 15])
          cylinder(h = 12, r = 10, center = true, $fn = 12);
    }

    // Broad, neutral wings make the silhouette read at thumbnail size.
    translate([42, -32, 5]) cube([12, 64, 4]);
    translate([-52, -31, 5]) cube([10, 62, 7]);

    // Abstract headrest and engine cover.
    translate([-21, -8, 6]) cube([14, 16, 12]);
    hull() {
      translate([-34, -10, 6]) cube([13, 20, 8]);
      translate([-20, -7, 6]) cube([8, 14, 11]);
    }
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
  else if (model == "headphone-stand") headphone_stand();
  else if (model == "pen-tray") pen_tray();
  else if (model == "cable-comb") cable_comb();
  else if (model == "drawer-label-clip") label_clip();
  else if (model == "soap-dish") soap_dish();
  else if (model == "plant-trellis") plant_trellis();
  else if (model == "tealight-lantern") tealight_lantern();
  else if (model == "picture-stand") picture_stand();
  else if (model == "business-card-holder") card_holder();
  else if (model == "plant-saucer") plant_saucer();
  else if (model == "measuring-scoop") measuring_scoop();
  else if (model == "bag-sealer") bag_sealer();
  else if (model == "hex-coaster") hex_coaster();
  else if (model == "mini-funnel") mini_funnel();
  else if (model == "tube-squeezer") tube_squeezer();
  else if (model == "spacer-set") spacer_set();
  else if (model == "corner-jig") corner_jig();
  else if (model == "drill-guide") drill_guide();
  else if (model == "star-knob") star_knob();
  else if (model == "hinge-pin") hinge_pin();
  else if (model == "furniture-foot") furniture_foot();
  else if (model == "hose-adapter") hose_adapter();
  else if (model == "puzzle-tile") puzzle_tile();
  else if (model == "spinning-top") spinning_top();
  else if (model == "open-wheel-toy-racer") open_wheel_toy_racer();
}
