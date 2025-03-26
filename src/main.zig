const std = @import("std");
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Condition = Thread.Condition;
const Allocator = std.mem.Allocator;

// Task type: Can be a function pointer or an async frame (for coroutines)
const Task = struct {
    func: *const fn () void, // Sync task
    // async_frame: anyframe, // Uncomment for async support
};

// Thread-safe task queue
const TaskQueue = struct {
    mutex: Mutex = .{},
    queue: std.DoublyLinkedList(Task) = .{},
    cond: Condition = .{},

    fn enqueue(self: *TaskQueue, task: Task) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const node = std.heap.page_allocator.create(std.DoublyLinkedList(Task).Node) catch unreachable;
        node.data = task;
        self.queue.append(node);
        self.cond.signal(); // Notify a waiting worker
    }

    fn dequeue(self: *TaskQueue) ?Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.queue.len == 0) {
            self.cond.wait(&self.mutex);
        }

        const node = self.queue.popFirst() orelse return null;
        const task = node.data;

        // Safely destroy the node after use
        std.heap.page_allocator.destroy(node);

        return task;
    }
};

// Scheduler with dynamic thread scaling
const Scheduler = struct {
    allocator: Allocator,
    task_queue: *TaskQueue,
    workers: std.ArrayList(Thread),
    min_threads: usize,
    max_threads: usize,
    current_threads: usize = 0,
    shutdown: bool = false,
    mutex: Mutex = .{},
    cond: Condition = .{},

    fn init(allocator: Allocator, min_threads: usize, max_threads: usize) !*Scheduler {
        const self = try allocator.create(Scheduler);
        self.* = .{
            .allocator = allocator,
            .task_queue = try allocator.create(TaskQueue),
            .workers = std.ArrayList(Thread).init(allocator),
            .min_threads = min_threads,
            .max_threads = max_threads,
        };

        // Initialize the task queue
        self.task_queue.* = .{
            .mutex = .{},
            .queue = .{},
            .cond = .{},
        };

        return self;
    }

    fn deinit(self: *Scheduler) void {
        self.shutdown = true;
        self.cond.broadcast(); // Wake all workers to exit
        for (self.workers.items) |worker| worker.join();
        self.allocator.destroy(self.task_queue);
        self.allocator.destroy(self);
    }
    fn start(scheduler: *Scheduler) !void {
        for (0..scheduler.min_threads) |_| {
            const thread = try Thread.spawn(.{}, workerLoop, .{scheduler});
            try scheduler.workers.append(thread);
            scheduler.current_threads += 1;
        }
    }
};

// worker theread
//
// Worker thread logic
fn workerLoop(scheduler: *Scheduler) void {
    while (true) {
        const task = scheduler.task_queue.dequeue() orelse {
            if (scheduler.shutdown) break;
            continue;
        };

        // Execute the task
        task.func();

        // Optional: Dynamic thread scaling logic
        scheduler.mutex.lock();
        defer scheduler.mutex.unlock();
        if ((scheduler.task_queue.queue.len > scheduler.current_threads * 2) and
            (scheduler.current_threads < scheduler.max_threads))
        {
            // Spawn a new thread
            const new_thread = Thread.spawn(.{}, workerLoop, .{scheduler}) catch continue;
            scheduler.workers.append(new_thread) catch continue;
            scheduler.current_threads += 1;
        }
    }
}

// Start initial worker threads

// Step 3: Spawn Tasks and Use the Scheduler
//
// Example tasks
fn exampleTask1() void {
    std.debug.print("Task 1 executed\n", .{});
}

fn exampleTask2() void {
    std.debug.print("Task 2 executed\n", .{});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Initialize scheduler with 2 min and 4 max threads
    const scheduler = try Scheduler.init(allocator, 2, 4);
    try scheduler.start();

    // Enqueue tasks
    scheduler.task_queue.enqueue(.{ .func = exampleTask1 });
    scheduler.task_queue.enqueue(.{ .func = exampleTask2 });

    // Keep main thread alive to let workers execute tasks
    std.time.sleep(1_000_000_000); // Adjust as needed
    scheduler.deinit();
}
