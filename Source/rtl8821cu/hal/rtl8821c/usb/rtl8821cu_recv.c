/******************************************************************************
 *
 * Copyright(c) 2016 - 2017 Realtek Corporation.
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of version 2 of the GNU General Public License as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
 * more details.
 *
 *****************************************************************************/
#define _RTL8821CU_RECV_C_

#include <drv_types.h>			/* PADAPTER, rtw_xmit.h and etc. */
#include <hal_data.h>			/* HAL_DATA_TYPE */
#include "../../hal_halmac.h"		/* RX desc */
#include "../rtl8821c.h"		/* rtl8821c_query_rx_desc, rtl8821c_c2h_handler_no_io() */
#include "../../../../Driver/VendorGlue.hpp"	/* RTL8821Native: g_trx_diag / g_rx_frames_decoded telemetry */

/* RTL8821Native: RX straddle carry — the chip's USB burst packing lets
 * packets cross our 32KB transfer boundaries on this IC (RXBAD events:
 * payload parsed as descriptors). The stash/carry machinery lives in
 * Source/Compat/VendorOsDep8821.c. */
extern volatile uint32_t g_rx_reassemble;
extern volatile uint32_t g_rx_parse_knob;   /* knob 12: bit0 skip, bit1 resync, bit2 carry, bit3 skip-straddle */
extern volatile uint32_t g_rx_skip_pending; /* knob 12 bit3: bytes to skip blind in the next transfer */
int rtl8814native_rx_stage_prepend(const u8 **pbuf, s32 *transfer_len);
void rtl8814native_rx_stash_tail_export(const u8 *pbuf, s32 left, u16 desc_pkt_len);
void rtl8814native_rx_stage_reset(void);
void rtl8814native_rx_stage_consume(void);
extern volatile uint32_t g_rx_frames_decoded;	/* RTL8821Native: shared RX telemetry */

int rtl8821cu_init_recv_priv(PADAPTER padapter)
{
	return usb_init_recv_priv(padapter, INTERRUPT_MSG_FORMAT_LEN);
}

void rtl8821cu_free_recv_priv(PADAPTER padapter)
{
	usb_free_recv_priv(padapter, INTERRUPT_MSG_FORMAT_LEN);
}

/* RTL8821Native: the descriptor walk lost the packet boundary (USB burst
 * packing straddle or junk tail). Slide in 8-byte steps — Realtek packing
 * is 8-byte aligned — and return the offset of the first plausible
 * descriptor, or 0 when none. The bytes before it are unrecoverable.
 * A candidate must be followed by another plausible descriptor (or land
 * within 8 bytes of the end): one window alone has too many false hits
 * inside packet payload. */
static u32 rx_resync_offset(PADAPTER padapter, u8 *pbuf, s32 transfer_len)
{
	union recv_frame *probe = rtw_alloc_recvframe(&padapter->recvpriv.free_recv_queue);
	u32 off;

	if (!probe)
		return 0;
	_rtw_init_listhead(&probe->u.hdr.list);
	probe->u.hdr.precvbuf = NULL;
	probe->u.hdr.len = 0;
	for (off = RXDESC_SIZE; off + RXDESC_SIZE <= (u32)transfer_len; off += 8) {
		struct rx_pkt_attrib *a;
		u32 po;

		rtl8821c_query_rx_desc(probe, pbuf + off);
		a = &probe->u.hdr.attrib;
		po = RXDESC_SIZE + a->drvinfo_sz + a->shift_sz + a->pkt_len;
		if (a->pkt_len > 0 && a->pkt_len <= 12000 &&
		    a->drvinfo_sz <= 120 &&
		    (a->shift_sz == 0 || a->shift_sz == 2) &&
		    a->pkt_rpt_type <= C2H_PACKET) {
			po = _RND8(po);
			if (po <= (u32)transfer_len - off) {
				/* continuity: the next window must also parse
				 * plausibly, or the candidate ends the stream */
				u32 next = off + po;
				u8 ok = 0;

				if (next + RXDESC_SIZE > (u32)transfer_len)
					ok = 1;    /* candidate runs to the end */
				else {
					rtl8821c_query_rx_desc(probe, pbuf + next);
					a = &probe->u.hdr.attrib;
					po = RXDESC_SIZE + a->drvinfo_sz + a->shift_sz + a->pkt_len;
					if (a->pkt_len > 0 && a->pkt_len <= 12000 &&
					    a->drvinfo_sz <= 120 &&
					    (a->shift_sz == 0 || a->shift_sz == 2) &&
					    a->pkt_rpt_type <= C2H_PACKET &&
					    _RND8(po) <= (u32)transfer_len - next)
						ok = 1;
				}
				if (ok) {
					rtw_free_recvframe(probe, &padapter->recvpriv.free_recv_queue);
					return off;
				}
			}
		}
	}
	rtw_free_recvframe(probe, &padapter->recvpriv.free_recv_queue);
	return 0;
}

static u8 recvbuf2recvframe_proccess_normal_rx
(PADAPTER padapter, u8 *pbuf, struct rx_pkt_attrib *pattrib, union recv_frame *precvframe, _pkt *pskb)
{
	u8 ret = _SUCCESS;
	struct recv_priv *precvpriv = &padapter->recvpriv;
	_queue *pfree_recv_queue = &precvpriv->free_recv_queue;

#ifdef CONFIG_RX_PACKET_APPEND_FCS
	if (check_fwstate(&padapter->mlmepriv, WIFI_MONITOR_STATE) == _FALSE) {
		if (rtl8821c_rx_fcs_appended(padapter))
			pattrib->pkt_len -= IEEE80211_FCS_LEN;
	}
#endif

	if (rtw_os_alloc_recvframe(padapter, precvframe,
		(pbuf + pattrib->shift_sz + pattrib->drvinfo_sz + RXDESC_SIZE), pskb) == _FAIL) {

		rtw_free_recvframe(precvframe, pfree_recv_queue);
		ret = _FAIL;
		goto exit;
	}

	recvframe_put(precvframe, pattrib->pkt_len);

	/* RTL8821Native: wire the 8821C path into the shared telemetry.
	 * g_rx_frames_decoded and the g_trx_diag rx_* counters were only
	 * incremented in the 8814A parse path — on this IC the status
	 * output showed rx_frames=0 / mgmt=0 / data=0 forever, which was
	 * misread as "nothing delivered" (the 2026-11-24 rx_frames red
	 * herring). Mirror the 8814 counters here. */
	{
		u8 *tdata = pbuf + pattrib->shift_sz + pattrib->drvinfo_sz + RXDESC_SIZE;
		u8 fc0 = tdata[0];

		g_rx_frames_decoded++;
		g_trx_diag.rx_normal++;
		switch ((fc0 >> 2) & 0x3) {
		case 0:
			g_trx_diag.rx_mgmt++;
			if (fc0 == 0x80)
				g_trx_diag.rx_beacon++;
			else if (fc0 == 0x50)
				g_trx_diag.rx_probe_rsp++;
			break;
		case 1: g_trx_diag.rx_ctrl++; break;
		case 2: g_trx_diag.rx_data++; break;
		}
	}

	pre_recv_entry(precvframe, pattrib->physt ? (pbuf + RXDESC_OFFSET) : NULL);

exit:
	return ret;
}

int recvbuf2recvframe(PADAPTER padapter, void *ptr)
{
	u8 *pbuf;
	u8 pkt_cnt = 0;
	u32 pkt_offset;
	s32 transfer_len;
	u8 *pphy_status = NULL;
	union recv_frame *precvframe = NULL;
	struct rx_pkt_attrib *pattrib = NULL;
	HAL_DATA_TYPE *pHalData = GET_HAL_DATA(padapter);
	struct recv_priv *precvpriv = &padapter->recvpriv;
	_queue *pfree_recv_queue = &precvpriv->free_recv_queue;
	_pkt *pskb;
	_pkt *bound_skb;
	u32 nparsed = 0;
	u16 desc_pkt_len;
	u8 desc_drvinfo, desc_shift, desc_rpt;
	static u8 g_rx_zero_skip;

#ifdef CONFIG_USE_USB_BUFFER_ALLOC_RX
	pskb = NULL;
	transfer_len = (s32)((struct recv_buf *)ptr)->transfer_len;
	pbuf = ((struct recv_buf *)ptr)->pbuf;
#else /* !CONFIG_USE_USB_BUFFER_ALLOC_RX */
	pskb = (_pkt *)ptr;
	transfer_len = (s32)pskb->len;
	pbuf = pskb->data;
#endif /* CONFIG_USE_USB_BUFFER_ALLOC_RX */

	/* RTL8821Native (knob 12 bit3, skip-straddle): consume a pending
	 * straddle remainder BEFORE anything else — these bytes are the
	 * middle of a frame we already decided to drop, never a descriptor.
	 * Zero-length URBs consume 0 and leave the skip intact. */
	if (g_rx_skip_pending && transfer_len > 0) {
		if ((u32)transfer_len <= g_rx_skip_pending) {
			g_rx_skip_pending -= (u32)transfer_len;
			return _SUCCESS;
		}
		pbuf += g_rx_skip_pending;
		transfer_len -= (s32)g_rx_skip_pending;
		g_rx_skip_pending = 0;
	}

	/* RTL8821Native: nothing parseable in this completion (zero-length
	 * URB or a sub-descriptor tail). Return BEFORE prepending — a reparse
	 * without the continuation fails at the first descriptor, and the
	 * stash must stay intact for the next transfer. */
	if (transfer_len < RXDESC_SIZE)
		return _SUCCESS;

	bound_skb = pskb;

	/* RTL8821Native: rejoin a stashed tail (packet straddling the
	 * previous transfer) to this one. When the parse then runs on the
	 * staged copy, pskb no longer bounds the data. */
	if (g_rx_reassemble &&
	    rtl8814native_rx_stage_prepend(&pbuf, &transfer_len))
		bound_skb = NULL;


	/* RTL8821Native: capture the first descriptor of this transfer for
	 * the status dump ("Last RX Desc") — was 8814A-path-only before. */
	if (transfer_len >= 24)
		_rtw_memcpy(g_trx_diag.last_desc, pbuf, 24);

#ifdef CONFIG_USB_RX_AGGREGATION
	pkt_cnt = GET_RX_DESC_DMA_AGG_NUM_8821C(pbuf);
#endif

	do {
		precvframe = rtw_alloc_recvframe(pfree_recv_queue);
		if (precvframe == NULL) {
			/* RTW_INFO("%s()-%d: rtw_alloc_recvframe() failed! RX Drop!\n", __func__, __LINE__); */
			RTW_INFO("%s()-%d: rtw_alloc_recvframe() failed! RX Drop!\n", __func__, __LINE__);
			goto _exit_recvbuf2recvframe;
		}

		_rtw_init_listhead(&precvframe->u.hdr.list);
		precvframe->u.hdr.precvbuf = NULL;	/* can't access the precvbuf for new arch */
		precvframe->u.hdr.len = 0;

		rtl8821c_query_rx_desc(precvframe, pbuf);

		pattrib = &precvframe->u.hdr.attrib;

		if ((padapter->registrypriv.mp_mode == 0) && ((pattrib->crc_err) || (pattrib->icv_err))) {
			/* RTW_INFO("%s: RX Warning! crc_err=%d icv_err=%d, skip!\n", __func__, pattrib->crc_err, pattrib->icv_err); */
			RTW_INFO("%s: RX Warning! crc_err=%d icv_err=%d, skip!\n", __func__, pattrib->crc_err, pattrib->icv_err);

			rtw_free_recvframe(precvframe, pfree_recv_queue);
			goto _exit_recvbuf2recvframe;
		}

		pkt_offset = RXDESC_SIZE + pattrib->drvinfo_sz + pattrib->shift_sz + pattrib->pkt_len;

		/* RTL8821Native: zero-length descriptors are the chip's page
		 * padding between DMA agg bursts, not packets. Field capture:
		 * "pkt_len<=0(0) or pkt_offset(24/25)> transfer_len(...)" — the
		 * vendor code aborts here and the WHOLE remaining transfer is
		 * lost (assoc responses die in that window: auth succeeds,
		 * assoc times out — "sometimes not work after enter password").
		 * Skip the filler and keep parsing. Fillers may carry junk in
		 * the shift bits (seen shift=1) — only length/type checked.
		 * Advance 8B while the next dword is also zero (fillers may be
		 * 8B words, not full 24B descriptors), else the desc extent.
		 * Bounded: a drift into a zero-filled payload region must not
		 * eat the transfer. */
		if (pattrib->pkt_len == 0) {
			if ((g_rx_parse_knob & 1) && pattrib->drvinfo_sz <= 120 &&
			    pattrib->pkt_rpt_type <= C2H_PACKET && g_rx_zero_skip < 32) {
				u32 adv;

				if (transfer_len >= RXDESC_SIZE + 4 &&
				    *(u32 *)(pbuf + RXDESC_SIZE) == 0)
					adv = 8;
				else
					adv = _RND8(RXDESC_SIZE + pattrib->drvinfo_sz + pattrib->shift_sz);
				g_rx_zero_skip++;
				rtw_free_recvframe(precvframe, pfree_recv_queue);
				pbuf += adv;
				transfer_len -= (s32)adv;
				precvframe = NULL;
				continue;
			}
			g_rx_zero_skip = 0;
		} else {
			g_rx_zero_skip = 0;
		}

		if ((pattrib->pkt_len <= 0) || (pkt_offset > transfer_len)) {
			/* RTL8821Native: hexdump the bad descriptor — the
			 * "Cannot find adapter" garbage-mac_addr warnings come
			 * from parsing payload as descriptor fields, i.e. a
			 * packet straddling the transfer boundary under USB
			 * burst packing. Rate-limited to once per 32 events. */
			static u32 bad_desc_cnt;
			if ((bad_desc_cnt++ & 0x1F) == 0) {
				RTW_INFO("RXBAD#%u tlen=%d desc:", bad_desc_cnt,
					 transfer_len);
				for (int _i = 0; _i < 24; _i++)
					RTW_INFO(" %02x", pbuf[_i]);
				/* RTL8821Native: ground truth — the 24 bytes before
				 * the bad window (end of the previous packet) and
				 * the next 24 after it. Shows the real filler
				 * layout between packets. */
				RTW_INFO("\nRXBAD ctx-24: ");
				for (int _i = -24; _i < 0; _i++)
					RTW_INFO(" %02x", pbuf[_i]);
				RTW_INFO("\nRXBAD ctx+24: ");
				for (int _i = 24; _i < 48; _i++)
					RTW_INFO(" %02x", pbuf[_i]);
				RTW_INFO("\n");
			}
			RTW_INFO("%s()-%d: RX Warning!,pkt_len<=0(%d) or pkt_offset(%d)> transfer_len(%d)\n"
				, __func__, __LINE__, pattrib->pkt_len, pkt_offset, transfer_len);
			if (pkt_offset > transfer_len)
				/* RTW_INFO("%s()-%d: RX Warning!,RXDESC_SIZE(%d), drvinfo_sz(%d), shift_sz(%d),pkt_len(%d)\n" */
				/*	, __func__, __LINE__, RXDESC_SIZE, pattrib->drvinfo_sz, pattrib->shift_sz, pattrib->pkt_len); */
			RTW_INFO("%s()-%d: RX Warning!,RXDESC_SIZE(%d), drvinfo_sz(%d), shift_sz(%d),pkt_len(%d)\n"
				, __func__, __LINE__, RXDESC_SIZE, pattrib->drvinfo_sz, pattrib->shift_sz, pattrib->pkt_len);

			/* capture before the frame goes back to the free queue */
			desc_pkt_len = pattrib->pkt_len;
			desc_drvinfo = pattrib->drvinfo_sz;
			desc_shift = pattrib->shift_sz;
			desc_rpt = pattrib->pkt_rpt_type;
			rtw_free_recvframe(precvframe, pfree_recv_queue);
			{
				/* RTL8821Native (knob 12 bit3, skip-straddle): a
				 * sane head extending past this transfer is a
				 * REAL straddle. The 2026-11-24 19:02 boot proved
				 * the stash-completion path delivers CORRUPT
				 * frames (element parse failed / icv_err) — so do
				 * NOT re-parse/re-deliver: drop the frame and
				 * blindly skip the remaining bytes of its RND8
				 * extent (payload rest + pad) in the following
				 * transfer(s). The walk lands exactly on the next
				 * descriptor; the lost frame is recovered by
				 * protocol retry (auth 300 ms, TCP, next beacon). */
				u8 sane = desc_pkt_len > 0 && desc_pkt_len <= 12000 &&
					  desc_drvinfo <= 120 &&
					  desc_rpt <= C2H_PACKET;

				if (sane && (g_rx_parse_knob & 8)) {
					u32 extent = (u32)(RXDESC_SIZE + desc_drvinfo +
							   desc_shift + desc_pkt_len);
					u32 skip = _RND8(extent) - (u32)transfer_len;

					if (skip && skip < 32000) {
						static u32 skip_log_cnt;
						g_rx_skip_pending = skip;
						if ((skip_log_cnt++ & 0x3F) == 0)
							rtl_printk("RTL8814Native: skip-straddle %u B pending (len=%u have=%d)\n",
								   skip, desc_pkt_len,
								   transfer_len);
						goto _exit_recvbuf2recvframe;
					}
				}
			}
			/* RTL8821Native: straddle carry + resync.
			 * - Sane head descriptor that merely needs more bytes
			 *   (pkt_offset beyond this transfer): a packet still
			 *   waiting for its payload (straddle across >=2 chunk
			 *   boundaries, or a small/zero-length completion).
			 *   Keep the stash — the next transfer completes it.
			 * - Corrupt head (payload parsed as descriptor):
			 *   re-stashing would re-parse the same garbage every
			 *   transfer — the RX doom loop (rx_frames stuck at 0,
			 *   wifi list empty). 8-byte resync scan instead; when
			 *   none, drop the stash and this transfer's remainder
			 *   — never re-stash junk. */
			if (nparsed == 0) {
				u8 sane = desc_pkt_len > 0 && desc_pkt_len <= 12000 &&
				          desc_drvinfo <= 120 &&
				          desc_rpt <= C2H_PACKET;

				if (sane) {
					rtl8814native_rx_stash_tail_export(pbuf, transfer_len,
									   desc_pkt_len);
					goto _exit_recvbuf2recvframe;
				}
				{
					u32 resync = (g_rx_parse_knob & 2)
					    ? rx_resync_offset(padapter, pbuf, transfer_len) : 0;

					if (resync) {
						pbuf += resync;
						transfer_len -= (s32)resync;
						continue;
					}
				}
				if (bound_skb == NULL)
					/* staged head is garbage — break the doom loop */
					rtl8814native_rx_stage_reset();
				goto _exit_recvbuf2recvframe;
			}
			/* Packets parsed before the failure: a genuine boundary
			 * straddle — the tail starts at a real descriptor. */
			rtl8814native_rx_stash_tail_export(pbuf, transfer_len,
							   desc_pkt_len);
			goto _exit_recvbuf2recvframe;
		}

		switch (pattrib->pkt_rpt_type) {
		case C2H_PACKET:
			/* RTL8821Native: pass the C2H packet's own extent (desc +
			 * pkt_len) rather than the remaining transfer length —
			 * the original C2H header carries no length field, and
			 * with USB aggregation/padding the remainder overstates
			 * it. phydm then parses padding as report content
			 * (garbage macid -> page fault in ra_report_handler). */
			c2h_pre_handler_rtl8821c(padapter, pbuf, RXDESC_SIZE + pattrib->pkt_len);
			g_trx_diag.rx_c2h++;	/* RTL8821Native: 8821C path telemetry */
			/* C2H_PACKET doesn't use recvframe, so free it */
			rtw_free_recvframe(precvframe, pfree_recv_queue);
			break;
		case TX_REPORT1:
		case TX_REPORT2:
		case HIS_REPORT:
			/* RTW_INFO("%s: [WARNNING] RX type(%d) not be handled!\n", __func__, pattrib->pkt_rpt_type); */
			RTW_INFO("%s: [WARNNING] RX type(%d) not be handled!\n", __func__, pattrib->pkt_rpt_type);
			rtw_free_recvframe(precvframe, pfree_recv_queue);
			break;
		case NORMAL_RX:
		default:
			if (recvbuf2recvframe_proccess_normal_rx(padapter, pbuf, pattrib, precvframe, bound_skb) == _FAIL)
				goto _exit_recvbuf2recvframe;
			nparsed++;
			break;
		}

#ifdef CONFIG_USB_RX_AGGREGATION
		/* jaguar 8-byte alignment */
		pkt_offset = (u16)_RND8(pkt_offset);
		pkt_cnt--;
		pbuf += pkt_offset;
#endif
		transfer_len -= pkt_offset;
		precvframe = NULL;

		/* RTL8821Native: aggregation tail padding / stale bytes — not
		 * enough for a descriptor. Do not parse or stash it: junk here
		 * would corrupt the next transfer's first descriptor (DrogaBox
		 * 8814 note). */
	} while (transfer_len >= RXDESC_SIZE);

_exit_recvbuf2recvframe:

	/* RTL8821Native: this transfer delivered at least one frame — the
	 * straddle chain is healthy, release the age/stuck-head trackers
	 * (stage_consume was defined but never wired: the doom loop's age
	 * cap was unreachable because stage_prepend resets the age). */
	if (nparsed > 0)
		rtl8814native_rx_stage_consume();

	return _SUCCESS;
}
