module mecca.reactor.time_queue;

import std.string;

import mecca.lib.time;
import mecca.lib.reflection;
import mecca.containers.lists;
import mecca.lib.divide: S64Divisor;


class TooFarAhead: Error {
    this(string msg, string file=__FILE__, size_t line=__LINE__) {
        super(msg, file, line);
    }
}

struct CascadingTimeQueue(T, size_t numBins, size_t numLevels) {
    static assert ((numBins & (numBins - 1)) == 0);
    static assert (numLevels >= 1);
    static assert (numBins * numLevels < 256*8);
    enum spanInBins = numBins*(numBins^^numLevels-1) / (numBins-1);

    TscTimePoint baseTime;
    TscTimePoint poppedTime;
    long resolutionCycles;
    S64Divisor resolutionDenom;
    size_t offset;
    version(unittest) {
        ulong[numLevels] stats;
    }
    LinkedList!T[numBins][numLevels] bins;

    void open(Duration resolution, TscTimePoint startTime = TscTimePoint.now) {
        open(TscTimePoint.toCycles(resolution), startTime);
    }
    void open(long resolutionCycles, TscTimePoint startTime) {
        assert (resolutionCycles > 0);
        this.baseTime = baseTime;
        this.poppedTime = baseTime;
        this.resolutionCycles = resolutionCycles;
        this.resolutionDenom = S64Divisor(resolutionCycles);
        this.offset = 0;
        version (unittest) {
            this.stats[] = 0;
        }
    }

    @property Duration span() const nothrow {
        return TscTimePoint.toDuration(resolutionCycles * spanInBins);
    }

    void insert(T entry) {
        version (unittest) {
            stats[0]++;
        }
        if (!_insert(entry)) {
            throw new TooFarAhead("tp=%s baseTime=%s poppedTime=%s (%.3fs in future) offset=%s resolutionCycles=%s".format(
                    entry.timePoint, baseTime, poppedTime, (entry.timePoint - baseTime).total!"msecs" / 1000.0,
                            offset, resolutionCycles));
        }
    }

    private bool _insert(T entry) {
        if (entry.timePoint <= poppedTime) {
            bins[0][offset % numBins].append(entry);
            return true;
        }
        else {
            auto idx = (entry.timePoint.cycles - baseTime.cycles + resolutionCycles - 1) / resolutionDenom;
            auto origIdx = idx;
            foreach(i; IOTA!numLevels) {
                if (idx < numBins) {
                    enum magnitude = numBins ^^ i;
                    bins[i][(offset / magnitude + idx) % numBins].append(entry);
                    return true;
                }
                idx = idx / numBins - 1;
            }
            return false;
        }
    }

    /+static void discard(T entry) {
        LinkedList!T.discard(entry);
    }+/

    @property long cyclesTillNextEntry() {
        auto now = baseTime.cycles;
        foreach(i; IOTA!numLevels) {
            foreach(j; 0 .. numBins) {
                enum magnitude = numBins ^^ i;
                if (!bins[i][(offset / magnitude + j) % numBins].empty) {
                    return now - baseTime.cycles;
                }
                now += resolutionCycles * magnitude;
            }
        }
        return -1;
    }

    T pop(TscTimePoint now) {
        while (now >= poppedTime) {
            auto e = bins[0][offset % numBins].popHead();
            if (e !is null) {
                assert (e.timePoint <= now, "popped tp=%s now=%s baseTime=%s poppedTime=%s offset=%s resolutionCycles=%s".format(
                    e.timePoint, now, baseTime, poppedTime, offset, resolutionCycles));
                return e;
            }
            else {
                offset++;
                poppedTime += resolutionCycles;
                if (offset % numBins == 0) {
                    baseTime = poppedTime;
                    cascadeNextLevel!1();
                }
            }
        }
        return T.init;
    }

    private void cascadeNextLevel(size_t level)() {
        static if (level < numLevels) {
            version (unittest) {
                stats[level]++;
            }
            enum magnitude = numBins ^^ level;
            assert (offset >= magnitude, "level=%s offset=%s mag=%s".format(level, offset, magnitude));
            auto binToClear = &bins[level][(offset / magnitude - 1) % numBins];
            while ( !binToClear.empty ) {
                auto e = binToClear.popHead();
                auto succ = _insert(e);
                /+assert (succ && e._chain.owner !is null && e._chain.owner !is binToClear,
                    "reinstered succ=%s tp=%s level=%s baseTime=%s poppedTime=%s offset=%s resolutionCycles=%s".format(
                        succ, e.timePoint, level, baseTime, poppedTime, offset, resolutionCycles));+/
            }
            assert (binToClear.empty, "binToClear not empty, level=%s".format(level));
            if ((offset / magnitude) % numBins == 0) {
                cascadeNextLevel!(level+1);
            }
        }
    }
}

unittest {
    import std.stdio;
    import std.algorithm: count, map;
    import std.array;

    static struct Entry {
        TscTimePoint timePoint;
        string name;
        Entry* _next;
        Entry* _prev;
    }

    enum resolution = 50;
    enum numBins = 16;
    enum numLevels = 3;
    CascadingTimeQueue!(Entry*, numBins, numLevels) ctq;
    ctq.open(resolution, TscTimePoint(0));
    assert (ctq.spanInBins == 16 + 16^^2 + 16^^3);

    bool[Entry*] entries;
    Entry* insert(TscTimePoint tp, string name) {
        Entry* e = new Entry(tp, name);
        ctq.insert(e);
        entries[e] = true;
        return e;
    }

    insert(90.TscTimePoint, "e1");
    insert(120.TscTimePoint, "e2");
    insert(130.TscTimePoint, "e3");
    insert(160.TscTimePoint, "e4");
    insert(TscTimePoint(resolution*numBins-1), "e5");
    insert(TscTimePoint(resolution*numBins + 10), "e6");

    long then = 0;
    foreach(long now; [10, 50, 80, 95, 100, 120, 170, 190, 210, 290, resolution*numBins, resolution*(numBins+1), resolution*(numBins+1)+1]) {
        Entry* e;
        while ((e = ctq.pop(TscTimePoint(now))) !is null) {
            scope(failure) writefln("%s:%s (%s..%s, %s)", e.name, e.timePoint, then, now, ctq.baseTime);
            assert (e.timePoint.cycles/resolution <= now/resolution, "tp=%s then=%s now=%s".format(e.timePoint, then, now));
            assert (e.timePoint.cycles/resolution >= then/resolution, "tp=%s then=%s now=%s".format(e.timePoint, then, now));
            assert (e in entries);
            entries.remove(e);
        }
        then = now;
    }
    assert (entries.length == 0, "Entries not empty: %s".format(entries));

    auto e7 = insert(ctq.baseTime + resolution * (ctq.spanInBins - 1), "e7");

    auto caught = false;
    try {
        insert(ctq.baseTime + resolution * ctq.spanInBins, "e8");
    }
    catch (TooFarAhead ex) {
        caught = true;
    }
    assert (caught);

    auto e = ctq.pop(e7.timePoint + resolution);
    assert (e is e7, "%s".format(e));
}

unittest {
    import std.stdio;
    import mecca.containers.pools;
    import std.algorithm: min;
    import std.random;

    static struct Entry {
        TscTimePoint timePoint;
        ulong counter;
        Entry* _next;
        Entry* _prev;
    }

    // must set these for the UT to be reproducible
    const t0 = TscTimePoint(168513482286);
    const cyclesPerSecond = 2208014020;
    const cyclesPerUsec = cyclesPerSecond / 1_000_000;
    long toCycles(Duration dur) {
        enum HECTONANO = 10_000_000;
        long hns = dur.total!"hnsecs";
        return (hns / HECTONANO) * cyclesPerSecond + ((hns % HECTONANO) * cyclesPerSecond) / HECTONANO;
    }

    void testCTQ(size_t numBins, size_t numLevels, size_t numElems)(Duration resolutionDur) {
        FixedPool!(Entry, numElems) pool;
        CascadingTimeQueue!(Entry*, numBins, numLevels) ctq;

        TscTimePoint now = t0;
        long totalInserted = 0;
        long totalPopped = 0;
        long iterationCounter = 0;
        auto span = resolutionDur * ctq.spanInBins;
        auto end = t0 + toCycles(span * 2);
        long before = toCycles(10.msecs);
        long ahead = toCycles(span/2);

        pool.reset();
        ctq.open(toCycles(resolutionDur), t0);

        //uint seed = 3594633224; //1337;
        uint seed = unpredictableSeed();
        auto rand = Random(seed);
        scope(failure) writefln("seed=%s numBins=%s numLevels=%s resDur=%s iterationCounter=%s totalInserted=%s " ~
            "totalPopped=%s t0=%s now=%s", seed, numBins, numLevels, resolutionDur, iterationCounter, totalInserted,
                totalPopped, t0, now);

        void popReady(long advanceCycles) {
            auto prevNow = now;
            now += advanceCycles;
            uint numPopped = 0;
            Entry* e;
            while ((e = ctq.pop(now)) !is null) {
                assert (e.timePoint <= now, "tp=%s prevNow=%s now=%s".format(e.timePoint, prevNow, now));
                //assert (e.timePoint/ctq.baseFrequencyCyclesDenom >= prevNow/ctq.baseFrequencyCyclesDenom, "tp=%s prevNow=%s now=%s".format(e.timePoint, prevNow, now));
                numPopped++;
                pool.release(e);
            }
            //writefln("%8d..%8d: %s", (prevNow - t0) / cyclesPerUsec, (now - t0) / cyclesPerUsec, numPopped);
            totalPopped += numPopped;
        }

        while (now < end) {
            while (pool.numAvailable > 0) {
                auto e = pool.alloc();
                e.timePoint = TscTimePoint(uniform(now.cycles - before, min(end.cycles, now.cycles + ahead), rand));
                e.counter = totalInserted++;
                //writefln("insert[%s] at %s", e.counter, (e.timePoint - t0) / cyclesPerUsec);
                ctq.insert(e);
            }
            auto us = uniform(0, 130, rand);
            if (us > 120) {
                us = uniform(100, 1500, rand);
            }
            popReady(us * cyclesPerUsec);
            iterationCounter++;
        }
        popReady(ahead + ctq.resolutionCycles);
        auto covered = ctq.baseTime.diff!"cycles"(t0) / double(cyclesPerSecond);
        auto expectedCover = span.total!"msecs" * (2.5 / 1000);
        assert (covered >= expectedCover - 2, "%s %s".format(covered, expectedCover));

        writeln(totalInserted, " ", totalPopped, " ", ctq.stats);
        foreach(i, s; ctq.stats) {
            assert (s > 0, "i=%s s=%s".format(i, s));
        }

        assert (totalInserted - totalPopped == pool.numInUse, "(1) pool.used=%s inserted=%s popped=%s".format(pool.numInUse, totalInserted, totalPopped));
        assert (totalInserted == totalPopped, "(2) pool.used=%s inserted=%s popped=%s".format(pool.numInUse, totalInserted, totalPopped));
        assert (totalInserted > numElems * 2, "totalInserted=%s".format(totalInserted));
    }

    int numRuns = 0;
    foreach(numElems; [10_000 /+, 300, 1000, 4000, 5000+/]) {
        // spans 878s
        testCTQ!(256, 3, 10_000)(50.usecs);
        numRuns++;
    }
    assert (numRuns > 0);
}
