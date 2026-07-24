import {
  getMarkdownTheme,
  type ExtensionAPI,
  UserMessageComponent,
} from "@earendil-works/pi-coding-agent";
import { encodeFirstmateOperationalInput } from "./fm-operational-input.ts";

export { encodeFirstmateOperationalInput } from "./fm-operational-input.ts";

export const CALM_TRANSCRIPT_CLASSES = [
  "genuine-user-prompt",
  "genuine-agent-response",
  "assistant-thinking",
  "assistant-tool-call",
  "tool-result",
  "tool-image",
  "user-bash",
  "skill-invocation",
  "custom-message",
  "custom-entry",
  "compaction-summary",
  "branch-summary",
  "working-status",
  "command-status",
  "system-notice",
  "cache-notice",
  "project-trust-warning",
  "synthetic-user",
  "synthetic-assistant",
  "unknown",
] as const;

export type CalmTranscriptClass = (typeof CALM_TRANSCRIPT_CLASSES)[number];

const CALM_VISIBLE_CLASSES = new Set<CalmTranscriptClass>([
  "genuine-user-prompt",
  "genuine-agent-response",
]);

export const FIRSTMATE_SYNTHETIC_CONTEXT_TYPE = "firstmate-synthetic-input";
export const FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE = "firstmate-synthetic-input-presentation";
export const FIRSTMATE_CALM_PRESENTATION_EVENT = "firstmate:calm-presentation";
export const FIRSTMATE_PI_LAUNCH_BRIEF_ENV = "FM_FIRSTMATE_PI_LAUNCH_BRIEF";

export type CalmPresentationState = {
  active: boolean;
  stockExportRendering: boolean;
};

export const FIRSTMATE_SYNTHETIC_KINDS = [
  "session-start",
  "watcher",
  "turn-end-guard",
  "away-supervisor",
  "from-firstmate",
  "launch-brief",
  "legacy-operational",
] as const;

export type FirstmateSyntheticKind = (typeof FIRSTMATE_SYNTHETIC_KINDS)[number];
export type FirstmateInputSource = "interactive" | "rpc" | "extension";

type SyntheticDeliveryOptions = {
  deliverAs?: "steer" | "followUp" | "nextTurn";
  redrawPresentation?: () => void;
  triggerTurn?: boolean;
};

type FirstmateSyntheticPresentation = {
  content: string;
  kind: FirstmateSyntheticKind;
};

let calm = false;
let mountingSyntheticPresentation = false;
let syntheticPresentationRedraw: (() => void) | undefined;
let stockExportRendering = false;

export function calmTranscriptClassIsVisible(itemClass: CalmTranscriptClass): boolean {
  return CALM_VISIBLE_CLASSES.has(itemClass);
}

export function setCalmPresentation(active: boolean): void {
  calm = active;
}

export function setCalmStockExportRendering(active: boolean): void {
  stockExportRendering = active;
}

export function setFirstmateSyntheticPresentationRedraw(
  redraw: (() => void) | undefined,
): void {
  syntheticPresentationRedraw = redraw;
}

export function calmPresentationIsActive(): boolean {
  return calm;
}

export function calmPresentationHides(itemClass: CalmTranscriptClass): boolean {
  return calm && !stockExportRendering && !calmTranscriptClassIsVisible(itemClass);
}

// Live visibility trusts only the exact process-bound positional launch value.
// Public marker syntax is intentionally absent from this provenance gate.
export function classifyFirstmateLaunchInput(
  content: string,
  source: FirstmateInputSource,
  expectedEncodedLaunchBrief?: string,
): "launch-brief" | undefined {
  if (
    source === "interactive" &&
    expectedEncodedLaunchBrief !== undefined &&
    content === expectedEncodedLaunchBrief
  ) {
    return "launch-brief";
  }
  return undefined;
}

export function registerFirstmateSyntheticPresentation(pi: ExtensionAPI): void {
  pi.registerEntryRenderer<FirstmateSyntheticPresentation>(
    FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE,
    (entry) => {
      if (
        calmPresentationHides("synthetic-user") &&
        !mountingSyntheticPresentation
      ) {
        return undefined;
      }
      const data = entry.data;
      if (!data || typeof data.content !== "string") return undefined;
      return new UserMessageComponent(data.content, getMarkdownTheme());
    },
  );
}

export function deliverFirstmateSyntheticInput(
  pi: ExtensionAPI,
  content: string,
  kind: FirstmateSyntheticKind,
  options: SyntheticDeliveryOptions = {},
): void {
  const redrawPresentation =
    options.redrawPresentation ?? syntheticPresentationRedraw;
  const mountForRedraw =
    calmPresentationHides("synthetic-user") &&
    redrawPresentation !== undefined;
  mountingSyntheticPresentation = mountForRedraw;
  try {
    pi.appendEntry<FirstmateSyntheticPresentation>(FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE, {
      content,
      kind,
    });
  } finally {
    mountingSyntheticPresentation = false;
  }
  if (mountForRedraw) redrawPresentation?.();
  pi.sendMessage(
    {
      customType: FIRSTMATE_SYNTHETIC_CONTEXT_TYPE,
      content,
      display: false,
      details: { kind },
    },
    options,
  );
}
