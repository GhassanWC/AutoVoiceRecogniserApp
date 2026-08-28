import { Router } from 'express';
import { requireAuth } from '../../middleware/auth';
import { getStore } from '../../storage';

export const translationRouter = Router();

translationRouter.use(requireAuth);

/** List saved sessions (history). Live sessions are created over WebSocket. */
translationRouter.get('/history', async (req, res, next) => {
  try {
    const sessions = await getStore().getSessionsForUser(req.userId!);
    res.json({ sessions });
  } catch (error) {
    next(error);
  }
});

translationRouter.get('/history/:sessionId', async (req, res, next) => {
  try {
    const session = await getStore().getSession(req.params.sessionId);
    if (!session || session.userId !== req.userId) {
      res.status(404).json({ error: 'Session not found' });
      return;
    }
    const messages = await getStore().getMessagesForSession(session.id);
    res.json({ session, messages });
  } catch (error) {
    next(error);
  }
});

translationRouter.delete('/session/:sessionId', async (req, res, next) => {
  try {
    const deleted = await getStore().deleteSession(req.params.sessionId, req.userId!);
    if (!deleted) {
      res.status(404).json({ error: 'Session not found' });
      return;
    }
    res.json({ ok: true });
  } catch (error) {
    next(error);
  }
});

translationRouter.delete('/history', async (req, res, next) => {
  try {
    const deleted = await getStore().deleteAllSessionsForUser(req.userId!);
    res.json({ ok: true, deletedSessions: deleted });
  } catch (error) {
    next(error);
  }
});
