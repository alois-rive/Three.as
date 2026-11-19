// three.js Clock and Timer, fed by Rive's advance(seconds) instead of
// performance.now (a script has no wall clock): call tick / update with
// the seconds each advance gets.

export class Clock {
    autoStart: bool;
    startTime: f64 = 0;
    oldTime: f64 = 0;
    elapsedTime: f64 = 0;
    running: bool = false;
    private now: f64 = 0;

    constructor(autoStart: bool = true) {
        this.autoStart = autoStart;
    }

    /// Advances the clock's time source (Rive-only; call from advance).
    tick(seconds: f64): void {
        this.now += seconds;
    }

    start(): void {
        this.startTime = this.now;
        this.oldTime = this.startTime;
        this.elapsedTime = 0;
        this.running = true;
    }

    stop(): void {
        this.getElapsedTime();
        this.running = false;
        this.autoStart = false;
    }

    getElapsedTime(): f64 {
        this.getDelta();
        return this.elapsedTime;
    }

    /// Seconds since the last getDelta (or start).
    getDelta(): f64 {
        let diff: f64 = 0;
        if (this.autoStart && !this.running) {
            this.start();
            return 0;
        }
        if (this.running) {
            diff = this.now - this.oldTime;
            this.oldTime = this.now;
            this.elapsedTime += diff;
        }
        return diff;
    }
}

/// three.js's Timer: update once a frame, then read delta and elapsed.
/// update takes the frame's seconds (three.js takes a timestamp).
export class Timer {
    private delta: f64 = 0;
    private elapsed: f64 = 0;
    private timescale: f64 = 1;

    update(seconds: f64): Timer {
        this.delta = seconds * this.timescale;
        this.elapsed += this.delta;
        return this;
    }

    getDelta(): f64 { return this.delta; }
    getElapsed(): f64 { return this.elapsed; }
    getTimescale(): f64 { return this.timescale; }
    setTimescale(timescale: f64): Timer { this.timescale = timescale; return this; }
    reset(): Timer { this.delta = 0; this.elapsed = 0; return this; }
    dispose(): void {}
}
