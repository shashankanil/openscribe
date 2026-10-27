import { it, expect } from "vitest";
import { calendarDefaults, isDue, meetingLink, matchesExclusion, makePrompt, extendedEnd, missedCountdown, pruneDecisions, allowOccurrence, startOptions, type CalendarEvent } from "./calendarPolicy";
const now = 1_800_000_000_000;
const event = (extra: Partial<CalendarEvent> = {}): CalendarEvent => ({id:"event:occurrence",title:"Weekly sync",start:new Date(now).toISOString(),end:new Date(now+3600_000).toISOString(),calendarID:"work",calendarName:"Work",hasAttendees:true,excluded:false,isAllDay:false,...extra});
it("ports Swift selected/unanswered/current meeting cases and inclusive 2 minute boundary", () => {
  expect(isDue(event(),now,["work"],new Set(),true)).toBe(true);
  expect(isDue(event(),now,[],new Set(),true)).toBe(false);
  expect(isDue(event(),now,["work"],new Set([event().id]),true)).toBe(false);
  for (const extra of [{start:new Date(now+30_000).toISOString()},{start:new Date(now-121_000).toISOString()},{end:new Date(now-1).toISOString()},{excluded:true},{isAllDay:true}]) expect(isDue(event(extra),now,["work"],new Set(),true)).toBe(false);
  expect(isDue(event({start:new Date(now-120_000).toISOString()}),now,["work"],new Set(),true)).toBe(true);
});
it("requires guests or a link in meetings-only mode", () => {
  expect(isDue(event({hasAttendees:false}),now,["work"],new Set(),true)).toBe(false);
  expect(isDue(event({hasAttendees:false}),now,["work"],new Set(),false)).toBe(true);
  expect(isDue(event({hasAttendees:false,link:"https://meet.google.com/abc"}),now,["work"],new Set(),true)).toBe(true);
});
it("ports Swift link host checks across all supported providers", () => {
  for (const host of ["meet.google.com","us02web.zoom.us","teams.microsoft.com","teams.live.com","company.webex.com"]) expect(new URL(meetingLink(`Join https://${host}/meeting`)!).hostname).toBe(host);
  for (const url of ["https://zoom.us.evil.example/j/123","https://example.com/meet.google.com","file:///tmp/meeting","http://zoom.us/j/123","https://zoom.us@evil.example/path"]) expect(meetingLink(url)).toBeUndefined();
});
it("title exclusions ignore case, whitespace and empty rules", () => {
  expect(matchesExclusion(event(),[" SYNC "])).toBe(true); expect(matchesExclusion(event(),["","   ","personal"])).toBe(false);
  expect(isDue(event(),now,["work"],new Set(),true,["weekly"])).toBe(false);
});
it("60 second start/end deadlines, disabled auto-start and 15 minute extension", () => {
  expect(makePrompt(event(),"start",now,true)).toMatchObject({automatic:true,deadline:new Date(now+60_000).toISOString(),message:"Do you want to record this meeting?"});
  expect(makePrompt(event(),"start",now,false).automatic).toBe(false); expect(makePrompt(event(),"end",now,false).automatic).toBe(true);
  expect(extendedEnd(now-1000,now)).toBe(now+900_000); expect(extendedEnd(now+1000,now)).toBe(now+901_000);
  expect(missedCountdown(now,now+10_000)).toBe(false); expect(missedCountdown(now,now+10_001)).toBe(true);
});
it("occurrence skips survive serialization and allow clears handled only for skipped occurrences", () => {
  const skipped = JSON.parse(JSON.stringify({[event().id]:now+3600_000}));
  expect(isDue(event(),now,["work"],new Set(Object.keys(skipped)),true)).toBe(false);
  expect(isDue(event({id:"next"}),now,["work"],new Set(Object.keys(skipped)),true)).toBe(true);
  expect(allowOccurrence(event().id,skipped,{[event().id]:now})).toEqual({skipped:{},handled:{}});
  expect(allowOccurrence("other",skipped,{other:now}).handled).toEqual({other:now});
  expect(pruneDecisions({old:now-8*86400_000,recent:now},now)).toEqual({recent:now});
});
it("unattended capture remains local; explicit yes honors live preference", () => {
  expect(calendarDefaults.calendarEnabled).toBe(false); expect(calendarDefaults.calendarSources).toEqual([]);
  expect(startOptions(calendarDefaults,true)).toEqual({microphone:true,systemAudio:true,summarizeOnStop:true,liveTranscription:false});
  expect(startOptions(calendarDefaults,false).liveTranscription).toBe(true);
});
