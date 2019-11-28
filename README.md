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
{
    import std;
    globalLogLevel = LogLevel.info;
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
        ulong id()
        {
            return _id;
        }
    }
    //
    // start some arbitrary timer and timer which rearm itself for every 50ms
    //
    TimingWheels!Timer w;
    // each tick span 5 msecs
    enum Tick = 5.msecs;
    enum IOWakeUpInterval = 100; // msecs
    int  counter;
    auto rnd = Random(142);
    SysTime last = Clock.currTime;

    // convert duration to ticks
    auto durationToTicks(Duration d)
    {
        return d/Tick;
    }
    // timer event processing
    void process_timer(Timer t)
    {
        switch(t._name)
        {
            case "periodic":
                writefln("@ %s - delta: %sms (should be 50ms)", t._name, (Clock.currTime - last).split!"msecs".msecs);
                last = Clock.currTime;
                counter++;
                w.schedule(t, durationToTicks(50.msecs));
                break;
            default:
                writefln("@ %s", t._name);
                break;
        }
    }
    // create timers
    auto periodic_timer = new Timer("periodic");
    auto some_timer = new Timer("some");

    // schedule periodic timer for 50.msecs
    w.schedule(periodic_timer, durationToTicks(50.msecs));
    // schedule other timer
    w.schedule(some_timer, durationToTicks(32.msecs));

    while(counter < 10) // done after 10 iterations
    {
        // randomIoInterval to emulate IO event which can arrive at any time
        auto randomIoInterval = uniform(0, IOWakeUpInterval, rnd);
        // calculate time to next timer event
        auto nextTimerEvent = max(w.timeUntilNextEvent(Tick), 0.msecs);
        // wait for what should happen earlier
        auto time_to_sleep = min(randomIoInterval.msecs, nextTimerEvent);
        writefln("* sleep until timer event or random I/O for %s", time_to_sleep);

        Thread.sleep(time_to_sleep);

        // if we have some timers to execute then timeUntilNextEvent
        // will be less or equal to zero.
        while(w.timeUntilNextEvent(Tick) <= 0.msecs)
        {
            // how much we have to advance?
            auto ticks = w.ticksUntilNextEvent();
            // receive all expired timers
            auto wr = w.advance(ticks);
            foreach(t; wr.timers)
            {
                process_timer(t);
            }
        }
        // some random processing time
        Thread.sleep(uniform(0, 5, rnd).msecs);
    }
}
```