"""Pure-Python CPU work for the A/B benchmark: n-body, JSON and regex."""
import json
import re


def nbody(steps):
    bodies = [[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 39.47],
              [4.84, -1.16, -0.10, 0.60, 2.81, -0.02, 0.037],
              [8.34, 4.12, -0.40, -1.01, 1.82, 0.008, 0.011],
              [12.89, -15.11, -0.22, 1.08, 0.86, -0.01, 0.0017],
              [15.37, -25.91, 0.17, 0.97, 0.59, -0.03, 0.002]]
    for _ in range(steps):
        for i, a in enumerate(bodies):
            for b in bodies[i + 1:]:
                dx, dy, dz = a[0] - b[0], a[1] - b[1], a[2] - b[2]
                mag = 0.01 / (dx * dx + dy * dy + dz * dz) ** 1.5
                a[3] -= dx * b[6] * mag
                a[4] -= dy * b[6] * mag
                a[5] -= dz * b[6] * mag
                b[3] += dx * a[6] * mag
                b[4] += dy * a[6] * mag
                b[5] += dz * a[6] * mag
        for body in bodies:
            body[0] += 0.01 * body[3]
            body[1] += 0.01 * body[4]
            body[2] += 0.01 * body[5]


def jsonwork(n):
    doc = {"k%d" % i: [i, str(i) * 3, {"x": i / 3}] for i in range(2000)}
    for _ in range(n):
        json.loads(json.dumps(doc))


def regexwork(n):
    text = " ".join("word%d foo@bar%d.example 2026-11-%02d" % (i, i, i % 28 + 1) for i in range(5000))
    pat = re.compile(r"(\w+)@(\w+)\.example|\d{4}-\d{2}-\d{2}")
    for _ in range(n):
        sum(1 for _ in pat.finditer(text))


nbody(150000)
jsonwork(60)
regexwork(40)
