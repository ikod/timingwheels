![](https://github.com/ikod/timingwheels/workflows/CI/badge.svg)

Timing Wheels Implementation

Timing wheels is data structure to store and retrieve huge number of timers with O(1) complexity (at the cost of grouping them).

See

http://www.cs.columbia.edu/~nahum/w6998/papers/sosp87-timing-wheels.pdf

https://www.snellman.net/blog/archive/2016-07-27-ratas-hierarchical-timer-wheel/

https://cwiki.apache.org/confluence/display/KAFKA/Purgatory+Redesign+Proposal


Timing wheels do not operate on real time, but on abstract intervals (ticks). When scheduling a timer, you specify the number of ticks before it runs. The duration of the tick is set "outside" of the library and determines the accuracy with which the timers will be executed. Multiple timers can fall into one tick and will be saved and executed together.

This library require from Timer class to implement method `id()` which must return some kind of unique ID. Type of this id can be some integer type or string.


### API ###

#### Schedule timer ####
`schedule(timer, t);` - schedule timer for execution `t` ticks in the future. t must be > 0.

#### Cancel timer ####
`cancel(timer)` - drop timer from wheels. You can't cancel cancelled timer.

#### Advance ####
`advance(t)` - advance wheels on `t` ticks. Advance on single tick will return all timers scheduled for the next tick (if any). `t` must be in interval (0, 256].

#### ticksUntilNextEvent ####
`ticksUntilNextEvent()` return number of ticks without timers.

#### timeUntilNextEvent ####
`timeUnitNextEvent(Tick)` return real time to next timer using provided tick duration.

Here is complete example with comments

```d
    import std;
    globalLogLevel = LogLevel.info;
    auto rnd = Random(142);

    /// track execution
    int  counter;
    SysTime last;

    /// this is our Timer
    class Timer
    {
        static ulong __id;
        private ulong _id;
        private string _name;
        this(string name)
        {
            _id = __id++;
            _name = name;
        }
        /// must provide id() method
        ulong id()
        {
            return _id;
        }
    }

    enum IOWakeUpInterval = 100; // to simulate random IO wakeups in interval 0 - 100.msecs

    // each tick span some time interval - this is our link with time in reality
    auto Tick = 5.msecs;

    TimingWheels!Timer w;
    w.init();
    auto durationToTicks(Duration d)
    {
        // we have to adjust w.now and realtime 'now' before scheduling timer
        auto real_now = Clock.currStdTime;
        auto tw_now = w.currStdTime(Tick);
        auto delay = (real_now - tw_now).hnsecs;
        return (d + delay)/Tick;
    }
    void process_timer(Timer t)
    {
        switch(t._name)
        {
            case "periodic":
                if ( last.stdTime == 0)
                {
                    // initialize tracking
                    last = Clock.currTime - 50.msecs;
                }
                auto delta = Clock.currTime - last;
                shouldApproxEqual((1e0*delta.split!"msecs".msecs), 50e0,1e-1);
                writefln("@ %s - delta: %sms (should be 50ms)", t._name, (Clock.currTime - last).split!"msecs".msecs);
                last = Clock.currTime;
                counter++;
                w.schedule(t, durationToTicks(50.msecs)); // rearm
                break;
            default:
                writefln("@ %s", t._name);
                break;
        }
    }
    // emulate some random initial delay
    auto randomInitialDelay = uniform(0, 500, rnd).msecs;
    Thread.sleep(randomInitialDelay);
    //
    // start one arbitrary timer and one periodic timer
    //
    auto some_timer = new Timer("some");
    auto periodic_timer = new Timer("periodic");
    w.schedule(some_timer, durationToTicks(32.msecs));
    w.schedule(periodic_timer, durationToTicks(50.msecs));

    while(counter < 10)
    {
        auto realNow = Clock.currStdTime;
        auto randomIoInterval = uniform(0, IOWakeUpInterval, rnd).msecs;
        auto nextTimerEvent = max(w.timeUntilNextEvent(Tick, realNow), 0.msecs);
        // wait for what should happen earlier
        auto time_to_sleep = min(randomIoInterval, nextTimerEvent);
        writefln("* sleep until timer event or random I/O for %s", time_to_sleep);
        Thread.sleep(time_to_sleep);
        // make steps if required
        int ticks = w.ticksToCatchUp(Tick, Clock.currStdTime);
        if (ticks > 0)
        {
            auto wr = w.advance(ticks);
            foreach(t; wr.timers)
            {
                process_timer(t);
            }
        }
        // emulate some random processing time
        Thread.sleep(uniform(0, 5, rnd).msecs);
    }
}
```