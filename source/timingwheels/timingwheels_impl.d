///
module timingwheels.timingwheels_impl;

import std.datetime;
import std.exception;
import std.typecons;
import std.format;
import std.traits;
import std.range;
import std.algorithm;
import std.experimental.logger;

import std.experimental.allocator;
import std.experimental.allocator.mallocator: Mallocator;

import core.thread;
import core.memory;

import ikod.containers.hashmap;
import automem;

version(twtesting)
{
    import unit_threaded;
}


version(twtesting)
{
    private class Timer
    {
        static ulong _current_id;
        private
        {
            ulong   _id;
        }
        this() @safe @nogc
        {
            _id = _current_id;
            _current_id++;
        }
        ~this() @safe @nogc
        {

        }
        ulong id() @safe @nogc
        {
            return _id;
        }
        override string toString()
        {
            return "%d".format(_id);
        }
    }
}
///
/// scheduling error occurs at schedule() when ticks == 0 or timer already scheduled.
///
///
class ScheduleTimerError: Exception
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) @nogc @safe
    {
        super(msg, file, line);
    }
}
///
/// Cancel timer error occurs if you try to cancel timer which is not scheduled.
///
class CancelTimerError: Exception
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) @nogc @safe
    {
        super(msg, file, line);
    }
}
///
/// Advancing error occurs if number of ticks for advance not in range 0<t<=256
///
class AdvanceWheelError: Exception
{
    ///
    ///
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) @nogc @safe
    {
        super(msg, file, line);
    }
}

debug(timingwheels) @safe @nogc nothrow
{
    package
    void safe_tracef(A...)(string f, scope A args, string file = __FILE__, int line = __LINE__) @safe @nogc nothrow
    {
        bool osx,ldc;
        version(OSX)
        {
            osx = true;
        }
        version(LDC)
        {
            ldc = true;
        }
        debug (timingwheels) try
        {
            // this can fail on pair ldc2/osx, see https://github.com/ldc-developers/ldc/issues/3240
            if (!osx || !ldc)
            {
                () @trusted @nogc {tracef("%s:%d " ~ f, file, line, args);}();
            }
        }
        catch(Exception e)
        {
        }
    }    
}

pragma(inline)
private void dl_insertFront(L)(L *le, L** head)
{
    if ( *head == null)
    {
        le.next = le.prev = le;
    }
    else
    {
        auto curr_head = *head;
        le.prev = curr_head.prev;
        le.next = curr_head;
        curr_head.prev.next = le;
        curr_head.prev = le;
    }
    *head = le;
}

pragma(inline)
private void dl_unlink(L)(L *le, L** head)
in(*head != null)
{
    if (le.next == le && *head == le)
    {
        *head = null;
        return;
    }
    if (le == *head)
    {
        *head = le.next;        
    }
    le.next.prev = le.prev;
    le.prev.next = le.next;
}
pragma(inline)
private void dl_walk(L)(L** head)
{
    if (*head == null)
    {
        return;
    }
    auto le = *head;
    do
    {
        le = le.next;
    } while (le != *head);
}
pragma(inline)
private void dl_relink(L)(L* le, L** head_from, L** head_to)
in(le.prev !is null && le.next !is null)
{
    dl_unlink(le, head_from);
    dl_insertFront(le, head_to);
}

@("dl")
unittest
{
    globalLogLevel = LogLevel.info;
    struct LE
    {
        int p;
        LE *next;
        LE *prev;
    }
    LE* head1 = null;
    LE* head2 = null;
    auto le1 = new LE(1);
    auto le2 = new LE(2);
    dl_insertFront(le1, &head1);
    assert(head1 != null);
    dl_unlink(le1, &head1);
    assert(head1 == null);

    dl_insertFront(le1, &head1);
    assert(head1 != null);
    dl_insertFront(le2, &head1);
    dl_unlink(le1, &head1);
    assert(head1 != null);
    dl_unlink(le2, &head1);
    assert(head1 == null);

    dl_insertFront(le1, &head1);
    assert(head1 != null);
    dl_insertFront(le2, &head1);
    dl_unlink(le2, &head1);
    assert(head1 != null);
    dl_unlink(le1, &head1);
    assert(head1 == null);

    dl_insertFront(le1, &head1);
    dl_relink(le1, &head1, &head2);
    assert(head1 == null);
    assert(head2 != null);
}
///
/// This structure implements scheme 6.2 thom the
/// $(LINK http://www.cs.columbia.edu/~nahum/w6998/papers/sosp87-timing-wheels.pdf)
/// and supports several primitives:
/// $(UL
/// $(LI schedule timer in the future.)
/// $(LI cancel timer.)
/// $(LI time step (advance) - all timers expired at current time tick are extracted from wheels.)
/// )
/// Each operation take O(1) time.
/// 
struct TimingWheels(T)
{
    import core.bitop: bsr;

    private
    {
        alias TimerIdType = ReturnType!(T.id);
        alias allocator = Mallocator.instance;

        enum MASK = 0xff;
        enum LEVELS = 8;
        enum LEVEL_MAX = LEVELS - 1;
        enum SLOTS  = 256;
        enum FreeListMaxLen = 100;

        struct ListElement(T)
        {
            private
            {
                T               timer;
                ulong           scheduled_at;
                ushort          position;
                ListElement!T*  prev, next;
            }
        }
        struct Slot
        {
            ListElement!T* head;
        }
        struct Level
        {
            // now if counter of ticks processed on this level
            ulong       now;
            Slot[SLOTS] slots;
        }

        Level[LEVELS]   levels;
        ListElement!T*  freeList;
        int             freeListLen;
        HashMap!(TimerIdType, ListElement!T*)
                        ptrs;
        long            startedAt;
    }
    invariant
    {
        assert(freeListLen>=0);
    }
    alias Ticks = ulong; // ticks are 64 bit unsigned integers.

    // hashing ticks to slots
    // 8 levels, each level 256 slots, with of slot on each level 256 times
    // translate ticks to level
    // 0x00_00_00_00_00_00_00_00 <- ticks
    //   ↓  ↓  ↓  ↓  ↓  ↓  ↓  ↓
    //   □  □  □  □  □  □  □  □ \
    //   □  □  □  □  □  □  □  □ |
    //   .  .  .  .  .  .  .  . | 256 slots
    //   .  .  .  .  .  .  .  . |
    //   □  □  □  □  □  □  □  □ /
    //   7  6  5  4  3  2  1  0
    //                          <- 8 levels
    // each slot - double linked list of timers

    // ticks to level = bsr(ticks)/8
    pragma(inline) private pure int t2l(ulong t) @safe @nogc nothrow
    {
        if (t == 0)
        {
            return 0;
        }
        return bsr(t)/LEVELS;
    }
    // ticks to slot  = ticks >> (level*8)
    pragma(inline) private pure int t2s(ulong t, int l) @safe @nogc nothrow
    {
        return (t >> (l<<3)) & MASK;
    }
    // level to ticks
    // l[0] -> 256
    // l[1] -> 256*256
    // ...
    pragma(inline) private pure ulong l2t(int l) @safe @nogc nothrow
    {
        return SLOTS<<l;
    }
    ~this()
    {
        ptrs.clear;
        for(int l=0;l<=LEVEL_MAX;l++)
            for(int s=0; s<SLOTS; s++)
            {
                while(levels[l].slots[s].head)
                {
                    auto le = levels[l].slots[s].head;
                    dl_unlink(le, &levels[l].slots[s].head);
                    () @trusted {
                        GC.removeRange(le);
                        dispose(allocator, le);
                    }();
                }
            }
        while(freeList)
        {
            assert(freeListLen>0);
            auto n = freeList.next;
            () @trusted {
                GC.removeRange(freeList);
                dispose(allocator, freeList);
            }();
            freeListLen--;
            freeList = n;
        }
    }

    private ListElement!T* getOrCreate()
    {
        ListElement!T* result;
        if (freeList !is null)
        {
            result = freeList;
            freeList = freeList.next;
            freeListLen--;
            return result;
        }
        result = make!(ListElement!T)(allocator);
        () @trusted {
            GC.addRange(result, (*result).sizeof);
        }();
        return result;
    }
    private void returnToFreeList(ListElement!T* le)
    {
        if ( freeListLen >= FreeListMaxLen )
        {
            // this can be safely disposed as we do not leak ListElements outide this module
            () @trusted {
                GC.removeRange(le);
                dispose(allocator, le);
            }();
        }
        else
        {
            le.position = 0xffff;
            le.next = freeList;
            freeList = le;
            freeListLen++;
        }
    }
    void init()
    {
        startedAt = Clock.currStdTime;
    }
    /++ 
     + Return internal view on current time - it is time at the call to $(B init)
     + plus total number of steps multiplied by $(B tick) duration.
     + Params:
     +   tick = tick duration
     +/
    auto currStdTime(Duration tick)
    {
        return startedAt + levels[0].now * tick.split!"hnsecs".hnsecs;
    }
    ///
    /// Schedule timer to $(B ticks) ticks forward from internal 'now'.
    ///Params: 
    /// timer = timer to schedule;
    /// ticks = ticks in the future to schedule timer. (0 < ticks < ulong.max);
    ///Returns:
    ///  void
    ///Throws: 
    /// ScheduleTimerError
    ///   when thicks == 0
    ///   or when timer already scheduled
    ///
    void schedule(T)(T timer, const ulong ticks)
    {
        if (ticks == 0)
        {
            throw new ScheduleTimerError("ticks can't be 0");
        }
        auto timer_id = timer.id();
        if (ptrs.contains(timer_id))
        {
            throw new ScheduleTimerError("Timer already scheduled");
        }
        size_t level_index = 0;
        long t = ticks;
        long s = 1;     // width of the slot in ticks on level
        long shift = 0;
        while(t > s<<8) // while t > slots on level
        {
            t -= (SLOTS - (levels[level_index].now & MASK)) * s;
            level_index++;
            s = s << 8;
            shift += 8;
        }
        auto level = &levels[level_index];
        auto mask = s - 1;
        size_t slot_index = (level.now + (t>>shift) + ((t&mask)>0?1:0)) & MASK;
        auto slot       = &levels[level_index].slots[slot_index];
        debug(timingwheels) safe_tracef("use level/slot %d/%d, level now: %d", level_index, slot_index, level.now);
        auto le = getOrCreate();
        le.timer = timer;
        le.position = ((level_index << 8 ) | slot_index) & 0xffff;
        le.scheduled_at = levels[0].now + ticks;
        dl_insertFront(le, &slot.head);
        ptrs[timer_id] = le;
        debug(timingwheels) safe_tracef("scheduled timer id: %s, ticks: %s, now: %d, scheduled at: %s to level: %s, slot %s",
            timer_id, ticks, levels[0].now, le.scheduled_at, level_index, slot_index);
    }
    /// Cancel timer
    ///Params: 
    /// timer = timer to cancel
    ///Returns: 
    /// void
    ///Throws: 
    /// CancelTimerError
    ///  if timer not in wheel
    void cancel(T)(T timer)
    {
        // get list element pointer
        auto v = ptrs.fetch(timer.id());
        if ( !v.ok )
        {
            throw new CancelTimerError("Cant find timer to cancel");
        }
        auto le = v.value;
        immutable level_index = le.position>>8;
        immutable slot_index  = le.position & 0xff;
        assert(timer is le.timer);
        debug(timingwheels) safe_tracef("cancel timer, l:%d, s:%d", level_index, slot_index);
        dl_unlink(le, &levels[level_index].slots[slot_index].head);
        returnToFreeList(le);
        ptrs.remove(timer.id());
    }
    /// Number of ticks to rotate wheels until internal wheel 'now'
    /// catch up with real world realTime.
    /// Calculation based on time when wheels were stared and total 
    /// numer of ticks pasded.
    ///Params: 
    /// tick = your tick length (Duration)
    /// realTime = current real world now (Clock.currStdTime)
    ///Returns: ticks to advance so that we catch up real world current time
    int ticksToCatchUp(Duration tick, ulong realTime)
    {
        auto c = startedAt + tick.split!"hnsecs".hnsecs * levels[0].now;
        auto v = (realTime - c) / tick.split!"hnsecs".hnsecs;
        if ( v > 256 )
        {
            return 256;
        }
        return cast(int)v;
    }
    /// Time until next scheduled timer event.
    /// You provide tick size and current real world time.
    /// This function find ticks until next event and use time of the start and
    /// total steps executed to calculate time delta from $(B realNow) to next event.
    ///Params: 
    /// tick = your accepted tick duration.
    /// realNow = real world now, result of Clock.currStdTime
    ///Returns: time until next event. Can be zero or negative in case you have already expired events.
    ///
    Duration timeUntilNextEvent(const Duration tick, ulong realNow)
    {
        assert(startedAt>0, "Forgot to call init()?");
        immutable n = ticksUntilNextEvent();
        immutable target = startedAt + (levels[0].now + n) * tick.split!"hnsecs".hnsecs;
        auto delta =  (target - realNow).hnsecs;
        debug(timingwheels) safe_tracef("ticksUntilNextEvent=%s, tick=%s, startedAt=%s", n, tick, SysTime(startedAt));
        return delta;
    }

    ///
    /// Adnvance wheel and return all timers expired during wheel turn.
    //
    /// Params:
    ///   ticks = how many ticks to advance. Must be in range 0 <= 256
    /// Returns: list of expired timers
    ///
    auto advance(this W)(ulong ticks)
    {
        struct ExpiredTimers
        {
            HashMap!(TimerIdType, T)    _map;
            auto timers()
            {
                return _map.byValue;
            }
        }
        alias AdvanceResult = automem.RefCounted!(ExpiredTimers, Mallocator);
        if (ticks > l2t(0))
        {
            throw new AdvanceWheelError("You can't advance that much");
        }
        if (ticks == 0)
        {
            throw new AdvanceWheelError("ticks must be > 0");
        }
        debug(timingwheels) safe_tracef("advancing %d ticks", ticks);
        auto      result = AdvanceResult(ExpiredTimers());
        auto      level  = &levels[0];

        while(ticks)
        {
            ticks--;
            immutable now           = ++level.now;
            immutable slot_index    = now & MASK;
            auto      slot = &level.slots[slot_index];
            debug(timingwheels) safe_tracef("level 0, now=%s", now);
            while(slot.head)
            {
                auto le = slot.head;
                auto timer = le.timer;
                auto timer_id = timer.id();
                assert(!result._map.contains(timer_id), "Something wrong: we try to return same timer twice");
                debug(timingwheels) safe_tracef("return timer: %s, scheduled at %s", timer, le.scheduled_at);
                result._map[timer_id] = timer;
                dl_unlink(le, &slot.head);
                returnToFreeList(le);
                ptrs.remove(timer.id());
            }
            if (slot_index == 0)
            {
                advance_level(1);
            }
        }
        return result;
    }

    //
    // ticks until next event on level 0 or until next wheel rotation
    // If you have empty ticks it is safe to sleep - you will not miss anything, just wake up
    // at the time when next timer have to be processed.
    //Returns: number of safe "sleep" ticks.
    //
    private int ticksUntilNextEvent()
    out(r; r<=256)
    {
        int result = 1;
        auto level = &levels[0];
        immutable uint now = levels[0].now & MASK;
        auto slot = (now + 1) & MASK;
        //assert(level.slots[now].head == null);
        do
        {
            if (level.slots[slot].head != null)
            {
                break;
            }
            result++;
            slot = (slot + 1) & MASK;
        }
        while(slot != now);

        return min(result, 256-now);
    }

    private void advance_level(int level_index)
    in(level_index>0)
    {
        debug(timingwheels) safe_tracef("running advance on level %d", level_index);
        immutable now0 = levels[0].now;
        auto      level  = &levels[level_index];
        immutable now    = ++level.now;
        immutable slot_index = now & MASK;
        debug(timingwheels) safe_tracef("level %s, now=%s", level_index, now);
        auto slot = &level.slots[slot_index];
        debug(timingwheels) safe_tracef("haldle l%s:s%s timers", level_index, slot_index);
        while(slot.head)
        {
            auto listElement = slot.head;

            immutable delta = listElement.scheduled_at - now0;
            size_t lower_level_index = 0;
            long t = delta;
            size_t s = 1;     // width of the slot in ticks on level
            size_t shift = 0;
            while(t > s<<8) // while t > slots on level
            {
                t -= (SLOTS - (levels[lower_level_index].now & MASK)) * s;
                lower_level_index++;
                s = s << 8;
                shift += 8;
            }
            auto mask = s - 1;
            size_t lower_level_slot_index = (levels[lower_level_index].now + (t>>shift) + ((t&mask)>0?1:0)) & MASK;
            debug(timingwheels) safe_tracef("move timer id: %s, scheduledAt; %d to level %s, slot: %s (delta=%s)",
                listElement.timer.id(), listElement.scheduled_at, lower_level_index, lower_level_slot_index, delta);
            listElement.position = ((lower_level_index<<8) | lower_level_slot_index) & 0xffff;
            dl_relink(listElement, &slot.head, &levels[lower_level_index].slots[lower_level_slot_index].head);
        }
        if (slot_index == 0 && level_index < LEVEL_MAX)
        {
            advance_level(level_index+1);
        }
    }
}

version(twtesting):

@("TimingWheels")
unittest
{
    import std.stdio;
    globalLogLevel = LogLevel.info;
    TimingWheels!Timer w;
    w.init();
    assert(w.t2l(1) == 0);
    assert(w.t2s(1, 0) == 1);
    immutable t = 0x00_00_00_11_00_00_00_77;
    immutable level = w.t2l(t);
    assert(level==4);
    immutable slot = w.t2s(t, level);
    assert(slot == 0x11);
    auto timer = new Timer();
    () @nogc @safe {
        w.schedule(timer, 2);
        bool thrown;
        // check that you can't schedule same timer twice
        try
        {
            w.schedule(timer, 5);
        }
        catch(ScheduleTimerError e)
        {
            thrown = true;
        }
        assert(thrown);
        thrown = false;
        try
        {
            w.advance(1024);
        }
        catch(AdvanceWheelError e)
        {
            thrown = true;
        }
        assert(thrown);
        thrown = false;
        w.cancel(timer);
        w.advance(1);
    }();
    w = TimingWheels!Timer();
    w.init();
    w.schedule(timer, 1);
    auto r = w.advance(1);
    assert(r.timers.count == 1);
    w.schedule(timer, 256);
    r = w.advance(255);
    assert(r.timers.count == 0);
    r = w.advance(1);
    assert(r.timers.count == 1);
    w.schedule(timer, 256*256);
    int c;
    for(int i=0;i<256;i++)
    {
        r = w.advance(256);
        c += r.timers.count;
    }
    assert(c==1);
}
@("rt")
@Tags("noauto")
unittest
{
    globalLogLevel = LogLevel.info;
    TimingWheels!Timer w;
    Duration Tick = 5.msecs;
    w.init();
    ulong now = Clock.currStdTime;
    assert(now - w.currStdTime(Tick) < 5*10_000);
    Thread.sleep(2*Tick);
    now = Clock.currStdTime;
    assert((now - w.currStdTime(Tick))/10_000 - (2*Tick).split!"msecs".msecs < 10);
    auto toCatchUp = w.ticksToCatchUp(Tick, now);
    toCatchUp.shouldEqual(2);
    auto t = w.advance(toCatchUp);
    toCatchUp = w.ticksToCatchUp(Tick, now);
    toCatchUp.shouldEqual(0);
}
@("cancel")
unittest
{
    globalLogLevel = LogLevel.info;
    TimingWheels!Timer w;
    w.init();
    Timer timer0 = new Timer();
    Timer timer1 = new Timer();
    w.schedule(timer0, 256);
    w.schedule(timer1, 256+128);
    auto r = w.advance(255);
    assert(r.timers.count == 0);
    w.cancel(timer0);
    r = w.advance(1);
    assert(r.timers.count == 0);
    assertThrown!CancelTimerError(w.cancel(timer0));
    w.cancel(timer1);
}
@("ticksUntilNextEvent")
unittest
{
    globalLogLevel = LogLevel.info;
    TimingWheels!Timer w;
    w.init();
    auto s = w.ticksUntilNextEvent;
    assert(s==256);
    auto r = w.advance(s);
    assert(r.timers.count == 0);
    Timer t = new Timer();
    w.schedule(t, 50);
    s = w.ticksUntilNextEvent;
    assert(s==50);
    r = w.advance(s);
    assert(r.timers.count == 1);
}

@("load")
@Serial
unittest
{
    import std.array:array;
    globalLogLevel = LogLevel.info;
    enum TIMERS = 100_000;
    Timer._current_id = 1;
    auto w = TimingWheels!Timer();
    w.init();
    for(int i=1;i<=TIMERS;i++)
    {
        auto t = new Timer();
        w.schedule(t, i);
    }
    int counter;
    for(int i=1;i<=TIMERS;i++)
    {
        auto r = w.advance(1);
        auto timers = r.timers;
        auto t = timers.array()[0];
        assert(t.id == i, "expected t.id=%s, got %s".format(t.id, i));
        assert(timers.count == 1);
        counter++;
    }
    assert(counter == TIMERS, "expected 100 timers, got %d".format(counter));

    for(int i=1;i<=TIMERS;i++)
    {
        auto t = new Timer();
        w.schedule(t, i);
    }
    counter = 0;
    for(int i=TIMERS+1;i<=2*TIMERS;i++)
    {
        auto r = w.advance(1);
        auto timers = r.timers;
        auto t = timers.array()[0];
        assert(t.id == i, "expected t.id=%s, got %s".format(t.id, i));
        assert(timers.count == 1);
        counter++;
    }
    assert(counter == TIMERS, "expected 100 timers, got %d".format(counter));

}
// @("cornercase")
// @Serial
// unittest
// {
//     Timer._current_id = 1;
//     auto w = TimingWheels!Timer();
//     globalLogLevel = LogLevel.trace;
//     w.advance(254);
//     auto t = new Timer();
//     w.schedule(t, 511);
//     for(int i=0; i<511; i++)
//     {
//         w.advance(1);
//     }
// }

///
///
///
@("example")
@Tags("noauto")
@Values(1.msecs,2.msecs,3.msecs,4.msecs,5.msecs,6.msecs,7.msecs,8.msecs, 9.msecs,10.msecs)
@Serial
unittest
{
    import std;
    globalLogLevel = LogLevel.info;
    auto rnd = Random(142);
    auto Tick = getValue!Duration();
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

    // each tick span 5 msecs - this is our link with time in reality
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
                assert(delta - 50.msecs <= max(Tick + Tick/20, 5.msecs), "delta-50.msecs=%s".format(delta-50.msecs));
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
